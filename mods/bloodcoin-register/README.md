# Das Register

Ein Claude-Code-Mod für den Bloodcoin-Server. Er zeigt neben dem Chat, wie weit der Weg zum Base Mainnet ist, und hält den Server-Claude von gefährlichen Befehlen ab.

## Was er zeigt

- **Pane «Das Register»**: Countdown bis zum Go-Live, die Mainnet-Tore (I bis IX), die nächste Emission, der Mining-Test, der letzte Orakel-Report sowie Backup, Dienste, Offsite-Kopie und Festplatte.
- **Statuszeile**: `Register T−6 · Tore 2/9 · Emission 3 h 38 min`.
- **Band über der Eingabe**: Es erscheint nur, wenn es brennt, also wenn höchstens 5 Tage bis zum Abbruchpunkt bleiben und noch Tore offen sind, wenn das Backup fehlschlug, ein Dienst aus ist oder der Status veraltet ist. Mit «Heute ausblenden» bleibt es für den Rest des Tages weg.
- **Befehle**: `/register` öffnet das Pane. `/tor` listet die Tore auf, `/tor III erledigt` setzt eines (erlaubte Zustände: `offen`, `geplant`, `erledigt`, `verzichtet`). Tore setzt nur Michels eigene Eingabe. Wenn Claude den Befehl selbst auslöst, wird er abgewiesen.

## Der Wächter

| Befehl | Antwort |
| --- | --- |
| `forge script … --broadcast`, `forge create`, `cast send` an Mainnet oder Chain 8453 | gesperrt, solange ein Tor offen ist; danach fragt er Michel jedes Mal |
| Ausgeben oder Kopieren von Keystores, `.key`, `wallet.json`, `.env`, Passwortdateien, SSH-Schlüsseln; `cast wallet private-key`; `echo $PRIVATE_KEY`; `printenv` | immer gesperrt |
| Lesen solcher Dateien mit dem Read-Werkzeug | immer gesperrt |
| Löschen oder Überschreiben in Backup, Wallet, Keystore, `.ssh`, `.cre` oder `register/tore.json` | Michel wird gefragt |
| Dienste stoppen (`systemctl stop`, `docker compose down`, …) | Michel wird gefragt |

Der Wächter ist ein Sicherheitsgurt gegen Versehen, keine Festung. Wer es darauf anlegt, kann einen Befehl so umschreiben, dass ihn kein Muster erkennt.

## Daten

Der Mod liest zwei Dateien in `/opt/bloodcoin/register/`:

- `tore.json`: Termine und Tore. Die Vorlage liegt in `server/tore.json`, geändert wird sie mit `/tor`.
- `status.json`: Diese Datei schreibt `server/register-status.sh` per Cron alle 5 Minuten. Das Skript liest nur Zeitstempel und Zustände, nie den Inhalt von Schlüsseln oder Backups.

## Installation auf dem Server

```sh
mkdir -p /opt/bloodcoin/register
cp -r mods /opt/bloodcoin/mods
cp /opt/bloodcoin/mods/bloodcoin-register/server/tore.json /opt/bloodcoin/register/tore.json
install -m 755 /opt/bloodcoin/mods/bloodcoin-register/server/register-status.sh /usr/local/bin/register-status.sh
# vorher in register-status.sh BACKUP_DIR, BACKUP_LOG, ORAKEL_INDEX, DIENSTE prüfen
echo '*/5 * * * * root /usr/local/bin/register-status.sh' > /etc/cron.d/bloodcoin-register
/usr/local/bin/register-status.sh && cat /opt/bloodcoin/register/status.json

claude plugin marketplace add /opt/bloodcoin/mods
claude plugin install bloodcoin-register@bloodcoin-mods --scope user
```

Der Mod lädt in jeder Claude-Sitzung, die danach startet. Sobald die Storage Box läuft, `touch /opt/bloodcoin/register/offsite-ok`.

## Prüfen

```sh
claude plugin validate mods
claude plugin test mods/bloodcoin-register
```
