import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { StatusFile, Tor, ToreFile, ToreState } from '../types'
import { judgeBash, judgeFile } from './guard'
import type { GateSummary, Verdict } from './guard'

const PLUGIN = 'bloodcoin-register'
const PANE = 'bloodcoin-register'
const DATA_DIR = '/opt/bloodcoin/register'
const TORE_PATH = `${DATA_DIR}/tore.json`
const STATUS_PATH = `${DATA_DIR}/status.json`
const MINUTE = 60_000
const DAY = 86_400_000
const WEEK = 7 * DAY
// status.json kommt alle 5 Minuten vom Cronjob; älter als das ist verdächtig.
const STALE_MS = 30 * MINUTE

// Farben der Bloodcoin-Seiten: Leder, Pergament, Gold, Blut.
const C = {
  ground: '#1c120d',
  rule: '#3a271b',
  ink: '#e9dcc0',
  faded: '#a8957a',
  gold: '#c9a24a',
  blood: '#9b1b1e',
  alarm: '#e06b62',
  plan: '#d8b25c',
  alarmGround: '#2a0f0e',
}

const DEFAULT_TORE: ToreFile = {
  goLive: '2026-10-31T00:00:00+01:00',
  abbruch: '2026-10-30T20:00:00+01:00',
  emissionStart: '2026-10-25T15:18:00Z',
  miningTest: '2026-10-26T13:00:00Z',
  tore: [
    { nr: 'I', text: 'SSH nur mit Schlüssel', state: 'erledigt', datum: '2026-10-23' },
    { nr: 'II', text: 'Backup inkl. Keystores', state: 'erledigt', datum: '2026-10-24' },
    { nr: 'III', text: 'Offsite-Backup (Storage Box)', state: 'offen' },
    { nr: 'IV', text: 'Bratschi schriftlich', state: 'offen' },
    { nr: 'V', text: 'Mining-Test + PR #1 mergen', state: 'geplant' },
    { nr: 'VI', text: 'PR #2 Faktor ≤ 1.0, Redeploy', state: 'offen' },
    { nr: 'VII', text: 'S6 Orakel-Härtung', state: 'offen' },
    { nr: 'VIII', text: 'S7 Remote Control ohne root', state: 'offen' },
    { nr: 'IX', text: 'Audit oder bewusster Verzicht', state: 'offen' },
  ],
}

const STATES: readonly ToreState[] = ['offen', 'geplant', 'erledigt', 'verzichtet']

const SEAL = `<svg xmlns="http://www.w3.org/2000/svg" width="44" height="44" viewBox="0 0 44 44"><circle cx="22" cy="22" r="20" fill="#0d0806" stroke="#c9a24a" stroke-width="1.5"/><circle cx="22" cy="22" r="15.5" fill="none" stroke="#c9a24a" stroke-width="0.6" stroke-dasharray="1.5 2"/><path d="M22 11 C22 11 15 20 15 25 a7 7 0 0 0 14 0 C29 20 22 11 22 11 Z" fill="#9b1b1e"/></svg>`

// Bei jeder Änderung an den Formen den Tag erhöhen: Altes wird dann verworfen.
const tore = atom({ plugin: 'bloodcoin-register', key: 'tore' } as const, DEFAULT_TORE, { shape: 'tore-1' })
const status = atom({ plugin: 'bloodcoin-register', key: 'status' } as const, null, { shape: 'status-1' })
const now = atom({ plugin: 'bloodcoin-register', key: 'now' } as const, 0)
const bandHiddenDay = atom({ plugin: 'bloodcoin-register', key: 'bandHiddenDay' } as const, null)

function isTor(value: unknown): value is Tor {
  const t = value as Tor
  return (
    typeof t === 'object' &&
    t !== null &&
    typeof t.nr === 'string' &&
    typeof t.text === 'string' &&
    STATES.includes(t.state)
  )
}

function parseTore(text: string): ToreFile | null {
  try {
    const value = JSON.parse(text) as ToreFile
    const ok =
      typeof value.goLive === 'string' &&
      typeof value.abbruch === 'string' &&
      Array.isArray(value.tore) &&
      value.tore.every(isTor)
    return ok ? value : null
  } catch {
    return null
  }
}

function parseStatus(text: string): StatusFile | null {
  try {
    const value = JSON.parse(text) as StatusFile
    return typeof value.updatedAt === 'string' ? value : null
  } catch {
    return null
  }
}

export function summarize(file: ToreFile): GateSummary {
  const open = file.tore.filter(t => t.state !== 'erledigt' && t.state !== 'verzichtet')
  return { open: open.map(t => t.nr), total: file.tore.length }
}

// Schweizer Zeit: Sommerzeit vom letzten Sonntag im März bis zum letzten
// Sonntag im Oktober, jeweils 01:00 UTC.
function lastSunday(year: number, month: number): number {
  const last = new Date(Date.UTC(year, month + 1, 0, 1))
  return last.getTime() - last.getUTCDay() * DAY
}

function zurich(ms: number): Date {
  const year = new Date(ms).getUTCFullYear()
  const isSummer = ms >= lastSunday(year, 2) && ms < lastSunday(year, 9)
  return new Date(ms + (isSummer ? 2 : 1) * 3_600_000)
}

const pad = (n: number) => String(n).padStart(2, '0')

export function formatDay(ms: number): string {
  const d = zurich(ms)
  return `${pad(d.getUTCDate())}.${pad(d.getUTCMonth() + 1)}.`
}

export function formatTime(ms: number): string {
  const d = zurich(ms)
  return `${formatDay(ms)} ${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}`
}

export function formatSpan(ms: number): string {
  if (ms <= 0) return 'jetzt'
  const minutes = Math.floor(ms / MINUTE)
  const days = Math.floor(minutes / 1440)
  const hours = Math.floor((minutes % 1440) / 60)
  if (days > 0) return `${days} T ${hours} h`
  return `${hours} h ${pad(minutes % 60)} min`
}

export function nextEmission(start: string | undefined, at: number): number | null {
  if (start === undefined) return null
  const first = Date.parse(start)
  if (Number.isNaN(first)) return null
  if (at <= first) return first
  return first + Math.ceil((at - first) / WEEK) * WEEK
}

export function daysLeft(iso: string, at: number): number {
  return Math.ceil((Date.parse(iso) - at) / DAY)
}

async function readTore($: EngineInterface): Promise<ToreFile> {
  try {
    return parseTore(await $.fs.read(TORE_PATH)) ?? (await read($, tore))
  } catch {
    return read($, tore)
  }
}

async function refresh($: EngineInterface): Promise<void> {
  const at = await $.clock.now()
  const file = await readTore($)
  let stat: StatusFile | null = null
  try {
    stat = parseStatus(await $.fs.read(STATUS_PATH))
  } catch {
    stat = null
  }
  await update($, tore, () => file)
  await update($, status, () => stat)
  await update($, now, () => at)

  const { open, total } = summarize(file)
  const emission = nextEmission(file.emissionStart, at)
  const parts = [
    `Register T−${Math.max(0, daysLeft(file.goLive, at))}`,
    `Tore ${total - open.length}/${total}`,
  ]
  if (emission !== null) parts.push(`Emission ${formatSpan(emission - at)}`)
  $.ui.status(parts.join(' · '))
}

function stateColor(state: ToreState): { text: string; badge: string } {
  if (state === 'erledigt' || state === 'verzichtet') return { text: C.faded, badge: C.gold }
  if (state === 'geplant') return { text: C.ink, badge: C.plan }
  return { text: C.ink, badge: C.alarm }
}

export function alarms(file: ToreFile, stat: StatusFile | null, at: number): string[] {
  const list: string[] = []
  const { open } = summarize(file)
  const left = daysLeft(file.abbruch, at)
  if (open.length > 0 && left <= 5) {
    list.push(`Noch ${Math.max(0, left)} Tage bis zum Abbruchpunkt, ${open.length} Tore offen.`)
  }
  if (stat === null) {
    list.push('Kein Serverstatus: status.json fehlt oder ist kaputt.')
  } else {
    if (at - Date.parse(stat.updatedAt) > STALE_MS) list.push('Serverstatus ist älter als 30 Minuten.')
    if (stat.backup !== undefined && !stat.backup.ok) list.push('Das letzte Backup ist fehlgeschlagen.')
    const down = (stat.dienste ?? []).filter(d => !d.aktiv).map(d => d.name)
    if (down.length > 0) list.push(`Dienst aus: ${down.join(', ')}.`)
  }
  return list
}

function verdictOf(file: ToreFile, tool: string, input: unknown): Verdict {
  const args = (input ?? {}) as { command?: unknown; file_path?: unknown; notebook_path?: unknown }
  if (tool === 'Bash' && typeof args.command === 'string') {
    return judgeBash(args.command, summarize(file))
  }
  const path = typeof args.file_path === 'string' ? args.file_path : args.notebook_path
  if (['Read', 'Edit', 'Write', 'NotebookEdit'].includes(tool) && typeof path === 'string') {
    return judgeFile(tool, path)
  }
  return { decision: 'allow' }
}

export function applyTor(file: ToreFile, nr: string, state: ToreState, day: string): ToreFile | null {
  if (!file.tore.some(t => t.nr === nr)) return null
  return {
    ...file,
    tore: file.tore.map(t => (t.nr === nr ? { ...t, state, datum: day } : t)),
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'register',
      description: 'Das Register öffnen: Mainnet-Tore, Countdown, Kette und Server',
    })
    await $.command.register({
      name: 'tor',
      description: 'Ein Tor setzen, z. B. /tor III erledigt (offen, geplant, erledigt, verzichtet)',
    })
    await refresh($)
    $.clock.every(MINUTE, () => void refresh($))
    void $.ui.open({ id: PANE, title: 'Das Register' })

    return next(e)
  })

  on('command.run', { command: 'register' }, async $ => {
    await refresh($)
    await $.ui.open({ id: PANE, title: 'Das Register' })

    return { text: 'Das Register ist offen.' }
  })

  on('command.run', { command: 'tor' }, async ($, e) => {
    // Nur Michels eigene Eingabe darf ein Tor schliessen, nie Claude selbst.
    if (e.origin.kind !== 'composer' && e.origin.kind !== 'bridge') {
      return { text: 'Tore setzt nur Michel selbst.' }
    }
    const file = await readTore($)
    const [nr, word] = e.args.trim().split(/\s+/)
    if (nr === undefined || nr === '') {
      const lines = file.tore.map(t => `${t.nr}  ${t.text}: ${t.state}${t.datum ? ` (${t.datum})` : ''}`)
      return { text: lines.join('\n') }
    }
    const state = STATES.find(s => s === word?.toLowerCase())
    if (state === undefined) {
      return { text: `Unbekannter Zustand. Erlaubt: ${STATES.join(', ')}.` }
    }
    const at = await $.clock.now()
    const d = zurich(at)
    const day = `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}`
    const changed = applyTor(file, nr.toUpperCase(), state, day)
    if (changed === null) {
      return { text: `Tor ${nr} gibt es nicht. Tore: ${file.tore.map(t => t.nr).join(', ')}.` }
    }
    try {
      await $.fs.write(TORE_PATH, `${JSON.stringify(changed, null, 2)}\n`)
    } catch (error) {
      return { text: `Konnte ${TORE_PATH} nicht schreiben: ${String(error)}` }
    }
    await refresh($)
    const { open, total } = summarize(changed)

    return { text: `Tor ${nr.toUpperCase()} ist jetzt ${state}. Offen: ${open.length} von ${total}.` }
  })

  on('tool.check', async ($, e, next) => {
    const verdict = verdictOf(await readTore($), e.tool, e.input)
    if (verdict.decision === 'allow') return next(e)

    return verdict
  }).catch(($, e, next) =>
    next.called ? next(e) : { decision: 'deny', reason: 'Der Wächter des Registers ist ausgefallen; der Befehl bleibt gesperrt.' },
  )

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const els = $.ui.resolve(e)
    const { Box, Text, Button } = els
    const Svg = 'Svg' in els ? els.Svg : undefined
    const file = await read($, tore)
    const stat = await read($, status)
    const at = (await read($, now)) || (await $.clock.now())
    const { open, total } = summarize(file)
    const emission = nextEmission(file.emissionStart, at)
    const mining = file.miningTest === undefined ? null : Date.parse(file.miningTest)

    const row = (label: string, value: string, color: string = C.ink) => (
      <Box flexDirection="row" justifyContent="space-between">
        <Text color={C.ink}>{label}</Text>
        <Text color={color} tabular>
          {value}
        </Text>
      </Box>
    )

    const heading = (label: string) => (
      <Text color={C.faded} size="caption" weight="semibold">
        {label}
      </Text>
    )

    const backup =
      stat?.backup === undefined
        ? row('Backup 03:30', 'unbekannt', C.faded)
        : row(
            'Backup 03:30',
            `${stat.backup.ok ? 'ok' : 'FEHLER'}${stat.backup.last ? ` · ${formatTime(Date.parse(stat.backup.last))}` : ''}`,
            stat.backup.ok ? C.ink : C.alarm,
          )
    const dienste = stat?.dienste ?? []
    const down = dienste.filter(d => !d.aktiv)

    return (
      <Box flexDirection="column" backgroundColor={C.ground} paddingX={1} paddingY={1} gap={1}>
        <Box flexDirection="row" gap={1} alignItems="center">
          {Svg !== undefined && <Svg source={SEAL} alt="Bloodcoin-Siegel" width={44} height={44} />}
          <Box flexDirection="column">
            <Text color={C.gold} weight="semibold" size="heading">
              DAS REGISTER
            </Text>
            <Text color={C.faded} size="footnote">
              Bloodcoin · Weg zum Base Mainnet
            </Text>
          </Box>
        </Box>

        <Box flexDirection="column" borderStyle="single" borderColor={C.gold} paddingX={1}>
          {heading(`GO-LIVE ${formatDay(Date.parse(file.goLive))}`)}
          <Box flexDirection="row" justifyContent="space-between">
            <Text color={C.ink} size="title" weight="semibold" tabular>
              T − {Math.max(0, daysLeft(file.goLive, at))}
            </Text>
            <Text color={open.length > 0 ? C.alarm : C.gold} weight="semibold">
              {open.length > 0 ? `${open.length} von ${total} Toren offen` : 'Alle Tore zu'}
            </Text>
          </Box>
          <Text color={C.faded} size="footnote">
            Abbruchpunkt {formatTime(Date.parse(file.abbruch))}. Nicht alles zu, dann wird verschoben.
          </Text>
        </Box>

        <Box flexDirection="column">
          {heading('DIE TORE')}
          {file.tore.map(t => {
            const color = stateColor(t.state)
            return (
              <Box flexDirection="row" gap={1}>
                <Box width={5}>
                  <Text color={C.faded}>{t.nr}</Text>
                </Box>
                <Box flexGrow={1}>
                  <Text color={color.text} wrap="truncate-end">
                    {t.text}
                  </Text>
                </Box>
                <Text color={color.badge} weight="semibold" size="caption">
                  {t.state.toUpperCase()}
                </Text>
              </Box>
            )
          })}
        </Box>

        <Box flexDirection="column">
          {heading('KETTE (TESTNET)')}
          {emission !== null &&
            row('Nächste Emission', `${formatTime(emission)} · in ${formatSpan(emission - at)}`, C.gold)}
          {mining !== null &&
            !Number.isNaN(mining) &&
            row('Mining-Test', mining > at ? `${formatTime(mining)} · in ${formatSpan(mining - at)}` : `${formatTime(mining)} · vorbei`)}
          {stat?.orakel === undefined
            ? row('Letzter Orakel-Report', 'unbekannt', C.faded)
            : row(
                'Letzter Orakel-Report',
                `${stat.orakel.last ? formatTime(Date.parse(stat.orakel.last)) : 'keiner'} · ${stat.orakel.ok ? 'ok' : 'FEHLER'}`,
                stat.orakel.ok ? C.ink : C.alarm,
              )}
        </Box>

        <Box flexDirection="column">
          {heading('SERVER')}
          {backup}
          {row(
            'Dienste',
            dienste.length === 0 ? 'unbekannt' : down.length === 0 ? `${dienste.length} laufen` : `aus: ${down.map(d => d.name).join(', ')}`,
            dienste.length === 0 ? C.faded : down.length === 0 ? C.ink : C.alarm,
          )}
          {row(
            'Offsite-Kopie',
            stat?.offsite === undefined ? 'unbekannt' : stat.offsite ? 'ja' : 'keine',
            stat?.offsite === true ? C.ink : C.alarm,
          )}
          {typeof stat?.diskPct === 'number' &&
            row('Festplatte', `${stat.diskPct} % belegt`, stat.diskPct >= 85 ? C.alarm : C.ink)}
          <Text color={C.faded} size="caption">
            {stat === null ? 'Kein status.json gefunden.' : `Stand ${formatTime(Date.parse(stat.updatedAt))}`}
          </Text>
        </Box>

        <Box flexDirection="row" gap={1}>
          <Button key="refresh" label="Aktualisieren" onPress={() => refresh($)} />
        </Box>
        <Text color={C.faded} size="caption">
          Tor setzen: /tor III erledigt
        </Text>
      </Box>
    )
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const file = await read($, tore)
    const stat = await read($, status)
    const at = (await read($, now)) || (await $.clock.now())
    const today = formatDay(at)
    const list = alarms(file, stat, at)
    if (e.props.hasSurvey || list.length === 0 || (await read($, bandHiddenDay)) === today) {
      return next(e)
    }
    const { Box, Text, Button } = $.ui.resolve(e)
    const [first, ...rest] = list

    return (
      <Box flexDirection="row" gap={1} backgroundColor={C.alarmGround} borderStyle="single" borderColor={C.blood} paddingX={1}>
        <Box flexDirection="column" flexGrow={1}>
          <Text color={C.ink} weight="semibold">
            {first}
          </Text>
          {rest.length > 0 && <Text color={C.faded}>{rest.join(' ')}</Text>}
        </Box>
        <Button key="open" label="Register öffnen" onPress={() => $.ui.open({ id: PANE, title: 'Das Register' })} />
        <Button key="hide" label="Heute ausblenden" onPress={() => update($, bandHiddenDay, () => today)} />
      </Box>
    )
  })
}
