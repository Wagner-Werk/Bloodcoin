export type ToreState = 'offen' | 'geplant' | 'erledigt' | 'verzichtet'

export type Tor = { nr: string; text: string; state: ToreState; datum?: string }

export type ToreFile = {
  goLive: string
  abbruch: string
  emissionStart?: string
  miningTest?: string
  tore: Tor[]
}

export type Dienst = { name: string; aktiv: boolean }

export type StatusFile = {
  updatedAt: string
  backup?: { last: string | null; ok: boolean }
  offsite?: boolean
  dienste?: Dienst[]
  orakel?: { last: string | null; ok: boolean }
  diskPct?: number | null
}

declare module 'claude-code' {
  interface PluginState {
    'bloodcoin-register': {
      tore: Shaped<ToreFile>
      status: Shaped<StatusFile | null>
      now: number
      bandHiddenDay: string | null
    }
  }
}
