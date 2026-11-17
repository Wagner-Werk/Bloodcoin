# chain.json atomar speichern (Vorfall 15.11.2026)

## Was passiert ist

Am 15.11.2026 um 04:15 UTC wurde `/data/chain.json` des Bloodcoin-Knotens beim Schreiben
abgeschnitten (54.4 MB auf 40.4 MB, ungültiges JSON). Der Knoten crashte danach bei jedem Start
(Restart-Schleife). Die Backups vom 16. und 17.11. (03:30) enthielten die kaputte Datei, ohne dass
es jemand merkte. Wiederhergestellt wurde aus dem Backup vom 15.11.

Ursache im Code: `Blockchain.save` öffnete `chain.json` mit `open(path, "w")` und schrieb direkt
hinein. `"w"` leert die Datei sofort. Wird der Prozess während der ~0.3 s Schreibzeit beendet
(Container-Neustart, OOM, voller Datenträger), bleibt eine halbe Datei zurück. Bei 30-s-Blöcken
wird die Datei rund 2'900 Mal am Tag neu geschrieben, also ist das kein exotischer Zufall.
Warum der Prozess genau um 04:15 starb, zeigt der Code nicht. Siehe "Offene Fragen".

## Warum der Code hier liegt und nicht im Knoten-Code

Der Knoten-Code (`bloodcoin/chain.py`, `node.py`) ist **nicht** in diesem Repository. Er liegt nur
auf dem Server und als Kopie vom 11.10.2026 in den Projektdateien. Dieser Ordner enthält deshalb
den Fix als Paket, das auf dem Server eingespielt wird:

| Datei | Inhalt |
|---|---|
| `bloodcoin/storage.py` | neues Modul: atomares Schreiben, `.bak`, Laden mit Fallback |
| `patches/chain-und-node.patch` | Änderung an `chain.py` (save/load) und `node.py` (Start, Speichern) |
| `tests/test_storage.py` | 12 Tests, u. a. der Vorfall nachgestellt (Datei auf 74 % abgeschnitten) |
| `backup/bloodcoin-chain-check.sh` | Prüfung für das Backup-Skript, mit ntfy-Alarm |

Der Patch ist gegen den Stand vom 11.10. gebaut (sha256 `chain.py` = `09c474ad…`,
`node.py` = `08fa9ba7…`). Mit diesem Stand laufen alle 38 Tests grün (26 alte + 12 neue).
Ist der Server-Code neuer und der Patch passt nicht, muss die Änderung von Hand nachgezogen werden;
sie ist klein (zwei Methoden in `chain.py`, drei Stellen in `node.py`).

## Was sich ändert

**Speichern** (`storage.atomic_write_json`):
1. JSON in eine Temp-Datei im selben Verzeichnis schreiben (`chain.json.XXXX.tmp`), `flush` + `fsync`.
2. Die bisherige `chain.json` per Hardlink als `chain.json.bak` festhalten (keine 54-MB-Kopie).
3. `os.replace(tmp, chain.json)`: atomar. Es liegt immer entweder die alte oder die neue Datei
   vollständig da. Danach `fsync` aufs Verzeichnis.
4. Schlägt das Speichern fehl (z. B. Datenträger voll), bleibt die alte Datei unverändert, der
   Knoten loggt `FEHLER: Chain konnte nicht gespeichert werden` und läuft weiter. Vorher wäre
   dabei der Mining-Thread gestorben.

**Laden** (`Blockchain.load_or_none`, beim Knotenstart):
1. `chain.json` laden und vollständig prüfen (JSON, Genesis, alle Blöcke gültig).
2. Ist sie kaputt: Fehler laut loggen, `chain.json.bak` laden, die kaputte Datei als
   `chain.json.kaputt-<UTC-Zeit>` **beiseitelegen, nicht löschen**. Es fehlt dann höchstens der
   letzte Block, der neu gemint wird.
3. Sind beide kaputt: der Knoten startet **absichtlich nicht** und meldet `ChainFileError` mit
   klarem Text. Früher wäre bei einer gültigen, aber unbrauchbaren Datei still eine neue Chain ab
   Genesis entstanden und hätte beim nächsten Block die alte überschrieben.
4. Liegengebliebene `.tmp`-Dateien eines abgebrochenen Schreibens werden beim Start entfernt.

Nebeneffekt: Ein Backup, das die Live-Datei während eines Schreibvorgangs kopiert, bekommt jetzt
immer eine vollständige Version (das alte Inode bleibt beim Ersetzen lesbar).

---

## Server-Auftrag (zum Einfügen in den Thread "Bloodcoin erstellen")

> Nichts davon ist schon ausgeführt. Schritt 4 startet den Knoten neu: nur mit Michels Go.

**1. Code finden und vergleichen**

```
sha256sum <knoten-code>/bloodcoin/chain.py <knoten-code>/bloodcoin/node.py
```

Erwartet für den Stand, gegen den der Patch gebaut ist:
`09c474ade3ecafdda82c5f4f1d53f482e9a21ab06259c60acb92a3c59e6acf15` (chain.py) und
`08fa9ba72af77929449d484dbfb42a1ac2d943056f14caca9fde31c68aa14792` (node.py).
Weicht es ab: trotzdem `patch --dry-run` versuchen, bei Fehler die Änderung von Hand übernehmen.

**2. Einspielen** (im Ordner, der `bloodcoin/` enthält, vorher Kopie anlegen)

```
patch -p1 --dry-run < chain-und-node.patch
patch -p1 < chain-und-node.patch
cp storage.py bloodcoin/storage.py
cp test_storage.py tests/test_storage.py
```

**3. Tests** (in der Umgebung mit `cryptography`, z. B. im Image):

```
python3 -m pytest -q tests
```

Erwartet: alle grün, davon 12 in `test_storage.py`.

**4. Neu bauen und starten** (Michels Go): vorher die aktuelle `chain.json` aus dem Volume
sichern, dann Image neu bauen und den Knoten-Container neu starten. Im Log muss
`Chain geladen: Höhe …` mit der erwarteten Höhe stehen. Ab dem zweiten Block nach dem Start muss
im Volume `chain.json.bak` liegen.

**5. Backup-Prüfung einbauen** (Root, Michel)

`bloodcoin-chain-check.sh` nach `/usr/local/bin/` legen, ausführbar machen. Im täglichen
Backup-Skript (03:30) **nach** dem Kopieren der Chain ins Backup:

```
/usr/local/bin/bloodcoin-chain-check.sh <backup>/chain.json "$(cat /var/lib/bloodcoin-backup/letzte-hoehe 2>/dev/null || echo 0)"
```

- Exit 0: Backup als gut markieren (z. B. Datei `OK` daneben schreiben oder Ordner mit `-ok`
  benennen) und die Blockzahl nach `/var/lib/bloodcoin-backup/letzte-hoehe` schreiben.
- Exit 1: das Skript hat schon per ntfy alarmiert. Backup als `-KAPUTT` markieren, **nicht** als
  gut, und die gespeicherte Höhe nicht überschreiben.
- Geprüft wird die Kopie **im Backup**, nicht nur die Live-Datei, denn genau die Backup-Kopie war
  am 16. und 17.11. kaputt.
- Der zweite Parameter fängt auch eine Chain ab, die gültiges JSON ist, aber geschrumpft ist.
  Nach einer gewollten Wiederherstellung auf einen älteren Stand die Datei `letzte-hoehe` einmal
  von Hand anpassen.

**6. Aufbewahrung anpassen** (lokal und Storage Box): Alte Backups nur löschen, wenn die
**letzten 3 als gut markierten** Backups erhalten bleiben, egal wie alt. Sonst hätte eine
unbemerkte Beschädigung nach 30 Tagen alle guten Backups verdrängt.

**7. Zusätzlich prüfen**: die offsite-Sicherung (03:50) nimmt die lokale Backup-Datei mit. Sie
sollte nur Backups mit `OK`-Markierung hochladen oder die Markierung mitnehmen.

---

## Offene Fragen, die dieser Fix nicht beantwortet

1. **Warum starb der Prozess um 04:15 UTC?** Kandidaten: Datenträger voll (35 Minuten nach dem
   Offsite-Lauf um 03:50, der ein Archiv erzeugt), OOM-Kill, Container-Neustart. Prüfen:
   `journalctl --since "2026-11-15 04:00" --until "2026-11-15 04:30"`, `dmesg -T | grep -i -E "oom|killed"`,
   `docker events`-Log bzw. `docker inspect` (RestartCount, OOMKilled), `df -h`.
   Wenn der Datenträger voll war, verhindert dieser Fix die kaputte Datei, aber der Knoten kann
   dann trotzdem nicht speichern. Die Ursache bleibt zu beheben.
2. **Warum kam zweieinhalb Tage kein Alarm?** Laut Einrichtung prüft ein Monitoring alle
   5 Minuten mit ntfy. Ein Knoten in der Restart-Schleife hätte am 15.11. morgens auffallen
   müssen. Wenn der Alarm nicht kam oder ignoriert wurde, ist das die grössere Lücke als das
   Backup.
3. **Die Datei wächst ohne Ende und wird alle 30 s komplett neu geschrieben** (54 MB × ~2'900
   pro Tag ≈ 150 GB Schreiblast pro Tag, Tendenz steigend, und jedes Speichern hält die Sperre
   des Knotens). Atomar macht es sicher, nicht effizient. Mittelfristig: nur neue Blöcke anhängen
   (z. B. eine Zeile JSON pro Block) statt alles neu zu schreiben. Nicht Teil dieses PRs.
