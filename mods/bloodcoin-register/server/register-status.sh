#!/usr/bin/env bash
# Schreibt /opt/bloodcoin/register/status.json für den Mod "Das Register".
# Läuft per Cron alle 5 Minuten. Liest nur Zeitstempel und Zustände,
# nie den Inhalt von Schlüsseln oder Backups.
set -u

OUT_DIR=/opt/bloodcoin/register
# Auf dem Server anpassen:
BACKUP_DIR=/root/backups                 # Ordner mit den täglichen Backups
BACKUP_LOG=/var/log/bloodcoin-backup.log # Log des Backup-Skripts (letzte Zeile "OK" = gut)
ORAKEL_INDEX=/opt/bloodcoin/deploy/site/oracle-data/index.json
DIENSTE="bloodcoin caddy docker claude-remote-control"
OFFSITE_MARKER=/opt/bloodcoin/register/offsite-ok  # existiert, sobald die Storage Box läuft

mkdir -p "$OUT_DIR"

export BACKUP_DIR BACKUP_LOG ORAKEL_INDEX DIENSTE OFFSITE_MARKER OUT_DIR
python3 -I - <<'PY'
import json, os, subprocess, datetime, shutil

def iso(ts):
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).isoformat().replace('+00:00', 'Z')

now = datetime.datetime.now(datetime.timezone.utc).timestamp()
status = {'updatedAt': iso(now)}

# Backup: jüngste Datei im Backup-Ordner, ok wenn jünger als 26 Stunden
# und das Log nicht mit einem Fehler endet.
bdir = os.environ['BACKUP_DIR']
try:
    newest = max((os.path.getmtime(os.path.join(bdir, n)) for n in os.listdir(bdir)), default=None)
except OSError:
    newest = None
log_ok = True
try:
    with open(os.environ['BACKUP_LOG'], encoding='utf-8', errors='replace') as f:
        lines = [l.strip() for l in f if l.strip()]
    if lines and any(w in lines[-1].lower() for w in ('error', 'fehler', 'failed')):
        log_ok = False
except OSError:
    pass
status['backup'] = {
    'last': iso(newest) if newest else None,
    'ok': bool(newest and now - newest < 26 * 3600 and log_ok),
}

status['offsite'] = os.path.exists(os.environ['OFFSITE_MARKER'])

dienste = []
for name in os.environ['DIENSTE'].split():
    r = subprocess.run(['systemctl', 'is-active', '--quiet', name], stderr=subprocess.DEVNULL)
    dienste.append({'name': name, 'aktiv': r.returncode == 0})
status['dienste'] = dienste

# Orakel: Änderungszeit des Report-Index; ok wenn jünger als 8 Tage.
try:
    m = os.path.getmtime(os.environ['ORAKEL_INDEX'])
    status['orakel'] = {'last': iso(m), 'ok': now - m < 8 * 86400}
except OSError:
    status['orakel'] = {'last': None, 'ok': False}

u = shutil.disk_usage('/')
status['diskPct'] = round(u.used * 100 / u.total)

out = os.path.join(os.environ['OUT_DIR'], 'status.json')
tmp = out + '.neu'
with open(tmp, 'w', encoding='utf-8') as f:
    json.dump(status, f, ensure_ascii=False, indent=2)
os.replace(tmp, out)
PY
