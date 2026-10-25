// Der Wächter: entscheidet über Befehle des Server-Claude, bevor sie laufen.
// Er ist ein Sicherheitsgurt gegen Versehen, keine Festung gegen Absicht.

export type Verdict =
  | { decision: 'allow' }
  | { decision: 'ask' | 'deny'; reason: string }

const ALLOW: Verdict = { decision: 'allow' }

// Dateien mit Geheimnissen: Keystores, Schlüssel, Wallet, Passwörter, .env.
const SECRET_PATH =
  /(keystore|\.key\b|private[_-]?key|wallet\.json|mnemonic|seed[_-]?phrase|passw(or)?d|\.env\b|id_ed25519(?!\.pub)|id_rsa(?!\.pub))/i

// Befehle, die einen Dateiinhalt ausgeben oder wegkopieren.
const READ_OR_COPY =
  /(^|[\s;|&(`])(cat|tac|less|more|head|tail|xxd|od|hexdump|base64|strings|grep|rg|awk|sed|jq|cp|scp|rsync|curl|wget|nc|ncat|socat|tar|zip|gpg|openssl)\b/

// Wege, ein Geheimnis direkt auszugeben, ohne den Dateinamen zu nennen.
const SECRET_DUMP =
  /(cast\s+wallet\s+(private-key|decrypt-keystore|derive-private-key)|^\s*(printenv|env)\s*$|echo\s+[^;|&]*\$\{?\w*(PRIVATE|SECRET|MNEMONIC|PASSWORD|PASSPHRASE)\w*)/i

// Löschen oder Überschreiben.
const DESTROY =
  /(^|[\s;|&(`])(rm|shred|unlink|truncate|rmdir|mv)\b|find\b[^;|&]*\s-delete\b|(^|[^\d>&])>{1,2}\s*(?!&|\/dev\/null)[\w/.~$-]/

// Was nie ohne Michel gelöscht oder verschoben wird.
const PROTECTED_PLACE =
  /(backup|bloodcoin-wallet|wallet\.json|keystore|\.foundry|\.cre\b|\.ssh|register\/tore\.json)/i

// Senden an eine Kette.
const BROADCAST = /(forge\s+(script|create)\b[^;|&]*--broadcast|forge\s+create\b|cast\s+(send|publish)\b)/i
const MAINNET = /(mainnet|\b8453\b)/i

// Dienste, die Kette, Orakel und Seiten tragen.
const STOP_SERVICE =
  /(systemctl\s+(stop|disable|mask|kill)\b|docker\s+(rm|stop|kill)\b|docker\s+compose\s+(down|rm|stop)\b|docker-compose\s+(down|rm|stop)\b)/i

export type GateSummary = { open: string[]; total: number }

export function judgeBash(command: string, gates: GateSummary): Verdict {
  if (SECRET_DUMP.test(command) || (SECRET_PATH.test(command) && READ_OR_COPY.test(command))) {
    return {
      decision: 'deny',
      reason:
        'Vom Register gesperrt: privater Schlüssel. Schlüssel, Keystores, Passwörter und .env werden nie ausgegeben, kopiert oder verschickt. Wenn das wirklich nötig ist, macht Michel es selbst im Terminal.',
    }
  }

  if (BROADCAST.test(command) && MAINNET.test(command)) {
    if (gates.open.length > 0) {
      return {
        decision: 'deny',
        reason: `Vom Register gesperrt: Mainnet-Deploy. ${gates.open.length} von ${gates.total} Toren sind offen (${gates.open.join(', ')}). Erst alle Tore schliessen, dann fragt der Wächter Michel.`,
      }
    }

    return {
      decision: 'ask',
      reason: 'Alle Tore sind zu. Das sendet an das Base MAINNET und kostet echtes Geld. Michel, gibst du das frei?',
    }
  }

  if (DESTROY.test(command) && PROTECTED_PLACE.test(command)) {
    return {
      decision: 'ask',
      reason: 'Der Befehl löscht oder überschreibt etwas in Backup, Wallet, Keystore, SSH oder dem Register. Michel, ist das gewollt?',
    }
  }

  if (STOP_SERVICE.test(command)) {
    return {
      decision: 'ask',
      reason: 'Der Befehl stoppt oder entfernt einen Dienst (Knoten, Orakel, Börse oder Webseite). Michel, ist das gewollt?',
    }
  }

  return ALLOW
}

export function judgeFile(tool: string, path: string): Verdict {
  if (tool === 'Read' && SECRET_PATH.test(path)) {
    return {
      decision: 'deny',
      reason: 'Vom Register gesperrt: Diese Datei enthält Geheimnisse und wird nicht gelesen.',
    }
  }

  if (tool !== 'Read' && (SECRET_PATH.test(path) || /register\/tore\.json$/.test(path))) {
    return {
      decision: 'ask',
      reason: `Der Befehl ändert ${path}. Das ist eine Schlüssel- oder Register-Datei. Michel, ist das gewollt?`,
    }
  }

  return ALLOW
}
