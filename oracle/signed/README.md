# Plan B: eigener signierter Melder statt Chainlink

Stand: 7.11.2026, Orakel-Härtung S6 (Vorschlag mit 48 h Einspruchsfrist, Wächter, getrennter
Gas-Schlüssel). **Nicht deployt, nicht extern auditiert.** Das laufende S13 auf Base Sepolia nutzt
noch die Fassung ohne S6; S6 kommt mit dem Testlauf S14.

Der eigene Server meldet die CDC-Zahlen. Token, Emission und Staking bleiben unverändert, nur der
Oracle-Contract und der Melder-Job sind neu.

## Was hier liegt

| Datei | Zweck |
|---|---|
| `src/SignedMortalityOracle.sol` | Nimmt nur Vorschläge an, die der feste Melde-Schlüssel signiert hat (EIP-712, gilt nur für diesen Contract auf dieser Chain). Wirksam erst nach 48 h, der Wächter kann verwerfen. |
| `script/DeploySigned.s.sol` | Deploy mit diesem Oracle und dem `FounderLock`. Braucht `ORACLE_SIGNER`, `ORACLE_GUARDIAN` (muss eine andere Adresse sein), `FOUNDER_BENEFICIARY`, `INITIAL_MINT_BCUS`. |
| `oracle/signed/report.py` | `send`: CDC abfragen, prüfen, signieren, vorschlagen, ablegen. `execute`: fälligen Vorschlag wirksam machen. `verify`: abgelegte Meldung mit den heutigen CDC-Zahlen vergleichen. |
| `oracle/signed/test_report.py` | Unit-Tests der Prüfungen (`python3 -m unittest oracle/signed/test_report.py`). |
| `test/SignedOracle.t.sol` | Contract-Tests, dazu Fuzz- und Invariantentests in `test/fuzz/`. |

## Rollen

| Rolle | Wo | Darf |
|---|---|---|
| Melde-Schlüssel (`signer`) | Server, Keystore ohne ETH | Meldungen signieren, `retire` signieren |
| Gas-Schlüssel (`sender`) | Server, eigener Keystore, etwa 0,001 ETH | nur Transaktionen bezahlen (`propose`, `execute`). Der Contract erlaubt jedem das Einreichen, der Gas-Schlüssel hat also keine Rechte. |
| Wächter (`guardian`) | nur offline bei Michel (Empfehlung: Trezor-Konto), nie auf dem Server, nicht im Server-Backup | offenen Vorschlag verwerfen (`veto`, `vetoWithSig`), Melder abschalten (`retire`). Er kann **nicht** melden. |
| jeder | | signierte Vorschläge einreichen, fällige ausführen, Wächter-Signaturen einreichen |

Alle Rollen sind unveränderlich, es gibt keinen Besitzer. Der Konstruktor lehnt `signer == 0`,
`guardian == 0` und `signer == guardian` ab.

## Was der Contract prüft

- Signatur vom festen Melde-Schlüssel.
- Zwei Summen über je 4 Wochen: die letzten 4 Wochen und der Durchschnitt derselben 4 Wochen in den
  3 Vorjahren. Beide zwischen 80.000 und 1.000.000, Verhältnis zwischen 1:2 und 2:1.
- Woche: neuer als die letzte wirksame, mindestens 8 Wochen alt, ein Samstag. Das prüft schon
  `propose`, damit ein offener Vorschlag nicht erst beim Ausführen scheitert und hängen bleibt.
  `MortalityEmission` prüft beim Ausführen noch einmal.
- **Einspruchsfrist:** `propose` legt den Vorschlag nur ab. Wirksam wird er mit `execute`, frühestens
  48 h später. Bis zur Ausführung kann der Wächter ihn verwerfen, auch nach Ablauf der 48 h.
- **Mindestabstand:** zwischen zwei Vorschlägen mindestens 6 Tage, auch nach einem Veto, und ebenso
  zwischen zwei Ausführungen. Es ist immer höchstens ein Vorschlag offen.
- `MortalityEmission` bewegt den Faktor pro wirksamer Meldung um höchstens 0,05. Zusammen heisst das:
  höchstens 0,05 je 6 Tage, von 1,0 auf 0,5 also mindestens 54 Tage plus 48 h.
- `retire` schaltet den Melder endgültig ab, mit einer Signatur des Melde-Schlüssels oder des
  Wächters über `Retire()`, oder direkt vom Wächter aufgerufen. Der offene Vorschlag verfällt, der
  Faktor geht auf 1,0 zurück, die Emission läuft ohne Sterbe-Anpassung weiter.

## Was er nicht verhindert

Wer den Melde-Schlüssel hat, kann falsche Zahlen vorschlagen. Wirksam werden sie nur, wenn 48 h lang
niemand ein Veto einlegt. Schutz:

1. `report.py` selbst meldet nicht, wenn die CDC-Zahlen zu eigenen früheren Meldungen nicht passen
   (siehe unten). Das hilft gegen Fehler, nicht gegen einen Dieb mit eigenem Programm.
2. `oracle/watch/check.py` läuft alle 6 Stunden auf GitHub, also ausserhalb des Servers, prüft den
   offenen Vorschlag gegen die CDC und schickt bei Abweichung einen Alarm mit der Veto-Frist.
3. Michel verwirft mit dem Wächter-Schlüssel (Anleitung unten) und schaltet bei Diebstahl ab.

Geht der Wächter-Schlüssel verloren, fällt nur das Veto weg; Meldungen laufen nach 48 h normal durch.
Wird er gestohlen, kann der Dieb nur verwerfen oder abschalten (Faktor 1,0), nicht melden.

## Prüfungen in report.py vor dem Signieren

- Gleiche Grenzen wie der Contract (80.000 bis 1.000.000, 1:2 bis 2:1).
- Vergleich mit den letzten 8 eigenen Meldungen (`????-??-??.json`, Feld `weeks_used`): weicht eine
  dort verwendete CDC-Woche heute um mehr als `--max-drift` (Standard 3 %) ab, in welche Richtung
  auch immer, wird nicht gemeldet. Wochen, die in der heutigen Abfrage fehlen, zählen nicht. Eine
  unlesbare Meldedatei ist ein Fehler. Die echten Nachkorrekturen der CDC lagen von August bis
  November 2026 bei höchstens 0,94 %.
- Melde- und Gas-Schlüssel müssen verschiedene Adressen sein.
- Jeder Fehler: Exit-Code ungleich 0 und Push-Alarm (`NTFY_URL` oder `--ntfy-file`).

`send` macht vorher einen fälligen offenen Vorschlag wirksam. Ist ein Vorschlag offen, aber noch
nicht fällig, bricht `send` mit Alarm ab. Die Meldedatei bekommt `proposed_tx`, `proposed_at`,
`executable_at`, später `executed_tx` oder `vetoed: true`; `index.json` zeigt `status` (offen,
ausgeführt, verworfen) für die Prüfseite `oracle.html`.

## Server einrichten (S14)

1. Foundry auf dem Server (`cast --version`).
2. Melde-Schlüssel (signiert nur, braucht kein ETH):
   ```bash
   install -d -m 700 /root/bcus-oracle/keystore /root/secrets
   openssl rand -hex 32 > /root/secrets/bcus-oracle.password && chmod 600 /root/secrets/bcus-oracle.password
   cast wallet new /root/bcus-oracle/keystore --unsafe-password "$(cat /root/secrets/bcus-oracle.password)"
   cast wallet address --keystore /root/bcus-oracle/keystore/<datei> --password-file /root/secrets/bcus-oracle.password
   ```
   Die Adresse ist `ORACLE_SIGNER`.
3. Gas-Schlüssel (getrennt):
   ```bash
   install -d -m 700 /root/bcus-sender
   openssl rand -hex 32 > /root/secrets/bcus-sender.password && chmod 600 /root/secrets/bcus-sender.password
   cast wallet new /root/bcus-sender --unsafe-password "$(cat /root/secrets/bcus-sender.password)"
   ```
   Etwa 0,001 ETH auf Base an diese Adresse (eine Meldung braucht zwei Transaktionen, um 150.000 Gas
   zusammen). Beide Keystores und Passwörter ins tägliche Backup. Der Wächter **nicht**.
4. Wächter-Adresse von Michel (Trezor-Konto). Sie wird beim Deploy fest eingetragen und lässt sich
   danach nicht mehr ändern.
5. Deploy:
   ```bash
   export ORACLE_SIGNER=0x...        # Schritt 2
   export ORACLE_GUARDIAN=0x...      # Schritt 4, muss anders sein als ORACLE_SIGNER
   export FOUNDER_BENEFICIARY=0x...
   export INITIAL_MINT_BCUS=1000000
   forge script script/DeploySigned.s.sol --rpc-url $BASE_RPC --broadcast --account deployer
   ```
6. Probelauf, dann echter Lauf:
   ```bash
   python3 oracle/signed/report.py --ntfy-file /root/secrets/ntfy-url send --rpc $BASE_RPC --oracle 0x... \
     --signer-keystore /root/bcus-oracle/keystore/<datei> --signer-password-file /root/secrets/bcus-oracle.password \
     --sender-keystore /root/bcus-sender/<datei> --sender-password-file /root/secrets/bcus-sender.password \
     --out-dir /opt/bloodcoin/public/oracle --dry-run
   ```
7. Zeitplan: `send` montags 12:00 UTC wie bisher. Neu: `execute` mittwochs 13:00 UTC (gleiche
   Optionen ohne `--signer-*`). Beide melden Fehler per ntfy.
8. In `.github/workflows/oracle-watch.yml` die neue Oracle-Adresse und den Deploy-Block eintragen,
   das Repository-Secret `NTFY_URL` setzen.
9. Das alte Oracle (S13) per `retire` abschalten.

## Veto (Michel, mit dem Wächter-Schlüssel)

Kommt der Alarm «Vorschlag Woche X verdächtig, Veto bis …», zuerst die Woche bei data.cdc.gov
ansehen. Ist der Vorschlag falsch, gibt es zwei Wege.

**A. Direkt** (der Wächter braucht etwas ETH auf Base): auf Basescan beim Oracle «Write Contract»,
Wallet verbinden, `veto()` aufrufen. Bei Diebstahl des Melde-Schlüssels stattdessen `retire()`.

**B. Ohne ETH, per Signatur:** Michel signiert, jemand anderes (z. B. der Server mit dem
Gas-Schlüssel) reicht ein.
1. Offenen Vorschlag lesen: `cast call $ORACLE "pending()(uint64,uint64,uint64,uint64)" --rpc-url $BASE_RPC`
   ergibt `weekEnding` und `proposedAt` (erste und zweite Zeile).
2. Diese Datei `veto.json` anlegen (Chain-ID 8453 für Base, 84532 für Base Sepolia):
   ```json
   {"types":{"EIP712Domain":[{"name":"name","type":"string"},{"name":"version","type":"string"},
     {"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],
     "Veto":[{"name":"weekEnding","type":"uint256"},{"name":"proposedAt","type":"uint256"}]},
    "primaryType":"Veto",
    "domain":{"name":"Bloodcoin Mortality Oracle","version":"1","chainId":8453,"verifyingContract":"0xORACLE"},
    "message":{"weekEnding":"<weekEnding>","proposedAt":"<proposedAt>"}}
   ```
3. Signieren, z. B. mit dem Trezor: `cast wallet sign --trezor --data --from-file veto.json`.
   Der Trezor zeigt Domain und Nachricht an; prüfen, dass Oracle-Adresse und Woche stimmen.
4. Einreichen (beliebiger Absender): `cast send $ORACLE "vetoWithSig(bytes)" <signatur> ...`

Die Signatur gilt nur für genau diesen Vorschlag (Woche und Zeitpunkt). Für einen neuen Vorschlag
braucht es eine neue Signatur. Für das Abschalten per Signatur gilt dasselbe mit dem Typ
`Retire` ohne Felder (`"Retire":[]`, `"message":{}`) und `retire(bytes)`; dieser Weg ist
nur in den Forge-Tests geprüft, nicht mit `cast wallet sign --data`. Vor dem Ernstfall auf S14 einmal
mit `cast call` (ohne zu senden) ausprobieren.

## Getestet

- Forge: alle Contract-, Fuzz- und Invariantentests grün, darunter Frist, Abstand, Veto direkt und
  per Signatur, alte Veto-Signatur gilt nicht für neuen Vorschlag, drei Wege zu `retire`, Dieb mit
  10 Fälschungen (alle verworfen, Faktor bleibt 1,0; ohne Veto mindestens 54 Tage bis 0,5), Fuzz
  «höchstens eine Ausführung je 6 Tage».
- `python3 -m unittest oracle/signed/test_report.py`: Grenzen und Drift-Prüfung.
- Ende-zu-Ende auf einer lokalen Anvil-Chain (7.11.2026): Deploy mit Wächter, `send` schlägt vor,
  zweites `send` und zu frühes `execute` brechen mit Alarm ab, `execute` nach 48 h macht wirksam,
  `send` mit 5 % nachkorrigierter Woche meldet nicht, Veto per signierter Typed-Data-Datei
  (`cast wallet sign --data`) über `vetoWithSig`, `retire()` durch den Wächter setzt den Faktor auf 1,0.
- Nicht getestet: echter Abruf bei data.cdc.gov (aus der Testumgebung gesperrt), Trezor, Base.
