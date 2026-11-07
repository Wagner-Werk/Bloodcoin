# Orakel-Wache

`check.py` prüft die Meldungen von `SignedMortalityOracle`, ohne dem Server zu vertrauen. Es liest
die Meldungen direkt von der Chain, holt dieselben 16 Wochen bei data.cdc.gov und rechnet nach.
Der GitHub-Workflow `.github/workflows/oracle-watch.yml` macht das alle 6 Stunden (GitHub startet
geplante Läufe oft eine bis mehrere Stunden später).

Ab S6 wirkt eine Meldung erst 48 Stunden nach dem Vorschlag. Die Wache prüft deshalb auch den
offenen Vorschlag (`pending`). Passt er nicht zur CDC, kommt der Alarm, solange der Wächter ihn
noch verwerfen kann: «Vorschlag Woche X verdächtig, Veto bis …».

Wofür: Der Melder-Schlüssel liegt auf dem Server, damit die Meldung automatisch läuft. Wer den
Server übernimmt, kann damit plausible falsche Zahlen melden. Der Vertrag lässt pro Meldung nur
0,05 Faktor-Schritt zu, also bleibt Zeit. Diese Wache sorgt dafür, dass es auffällt, auch wenn der
Server selbst nichts mehr meldet oder seine Ablage gefälscht ist.

## Alarm

Der Lauf schlägt fehl (rot auf GitHub, Mail an den Besitzer des Workflows) bei:

| Fall | Grenze |
|---|---|
| Letzte 4 Wochen weichen von der CDC ab | unter -3 % oder über +1 % (die CDC trägt Tote nach, darum unten mehr Spiel) |
| Vorjahre weichen von der CDC ab | mehr als 1 % |
| Eine gemeldete Woche gibt es bei der CDC nicht | immer |
| Offener Vorschlag weicht von der CDC ab | gleiche Grenzen wie oben, Nachricht nennt die Veto-Frist |
| `Retired` | immer |
| Keine Meldung | länger als 15 Tage |

Ist das Repository-Secret `NTFY_URL` gesetzt (z. B. `https://ntfy.sh/<thema>`), geht der Alarm
zusätzlich als Push aufs Handy. Das Thema darf nicht auf dem eigenen Server laufen, sonst fällt der
Alarm mit dem Server aus.

Die Grenzen sind Startwerte. Nach den ersten echten Meldungen anschauen, wie stark die CDC
nachträgt, und bei Fehlalarmen anpassen.

## Bei Alarm

1. Meldung auf Basescan und die genannte Woche bei data.cdc.gov ansehen. Ist es ein Fehlalarm
   (CDC hat stark nachkorrigiert), Grenze anpassen.
2. Ist ein offener Vorschlag falsch: mit dem Wächter-Schlüssel verwerfen, bevor jemand `execute`
   aufruft (Anleitung in `oracle/signed/README.md`, «Veto»).
3. Ist der Melde-Schlüssel gestohlen: Server-Job stoppen und den Melder abschalten, mit dem Wächter
   (`retire()` direkt oder per Signatur) oder der vorab signierten `retire`-Signatur. Der Faktor
   geht dabei auf 1,0 zurück.

## Grenzen

- GitHub schaltet geplante Workflows ab, wenn im Repository 60 Tage lang nichts passiert. GitHub
  schickt vorher eine Mail; dann unter Actions mit einem Klick wieder einschalten.
- Mails zu geplanten Läufen gehen an den, der den Zeitplan zuletzt geändert hat. Darum zusätzlich
  `NTFY_URL` setzen.
- Die Wache prüft nur die letzten 21 Tage (nach Zeitstempel, nicht nach Blockzahl). Alles prüfen: `--days 0`.

## Von Hand

```bash
python3 oracle/watch/check.py --rpc https://sepolia.base.org \
  --oracle 0x6883Cba0F7daD8a4A998b346bF35d971aF0a8E19 --from-block 48284210
```
