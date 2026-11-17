#!/usr/bin/env bash
# Prüft eine chain.json (live oder aus einem Backup) und schlägt per ntfy Alarm, wenn sie kaputt ist.
#
#   bloodcoin-chain-check.sh <pfad/zu/chain.json> [mindest-bloecke]
#
# Exit 0 = Datei ist gültiges JSON, eine nicht leere Blockliste, letzter Block hat Höhe = Anzahl-1,
#          und (optional) mindestens <mindest-bloecke> Blöcke.
# Exit 1 = kaputt -> ntfy-Alarm wurde gesendet. Das Backup-Skript darf dieses Backup dann NICHT
#          als gut markieren.
#
# ntfy: NTFY_URL aus der Umgebung (z. B. aus /etc/bloodcoin-*.env), Format https://ntfy.sh/<thema>.
set -u

FILE="${1:?Pfad zur chain.json fehlt}"
MIN_BLOCKS="${2:-0}"

alarm() {
    echo "CHAIN-CHECK FEHLER: $1" >&2
    if [ -n "${NTFY_URL:-}" ]; then
        curl -fsS -m 15 -H "Title: Bloodcoin Backup: chain.json kaputt" -H "Priority: high" \
             -H "Tags: warning" -d "$1" "$NTFY_URL" >/dev/null || echo "ntfy-Versand fehlgeschlagen" >&2
    fi
    exit 1
}

[ -s "$FILE" ] || alarm "$FILE fehlt oder ist leer ($(hostname), $(date -u +%FT%TZ))"

RESULT="$(python3 -I - "$FILE" "$MIN_BLOCKS" <<'PY' 2>&1
import json, sys
path, min_blocks = sys.argv[1], int(sys.argv[2])
try:
    with open(path) as f:
        blocks = json.load(f)
except Exception as e:
    print(f"kein gültiges JSON: {type(e).__name__}: {e}")
    sys.exit(1)
if not isinstance(blocks, list) or not blocks:
    print("keine Blockliste"); sys.exit(1)
last = blocks[-1]
if not isinstance(last, dict) or last.get("height") != len(blocks) - 1:
    print(f"letzter Block hat Höhe {last.get('height') if isinstance(last, dict) else '?'}, erwartet {len(blocks) - 1}")
    sys.exit(1)
if len(blocks) < min_blocks:
    print(f"nur {len(blocks)} Blöcke, erwartet mindestens {min_blocks} (Chain geschrumpft?)")
    sys.exit(1)
print(f"OK: {len(blocks)} Blöcke, Höhe {last['height']}")
PY
)" || alarm "$FILE: $RESULT ($(stat -c %s "$FILE") Bytes, $(hostname), $(date -u +%FT%TZ))"

echo "$RESULT"
