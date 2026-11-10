import type { Heartbeat, Busy } from '../types'

export function serializeHeartbeat(h: Heartbeat): string {
  return JSON.stringify(h)
}

const STATES: readonly Busy[] = ['busy', 'idle', 'shell']

/** Tolerant parse: a half-written or foreign file is skipped, never thrown. */
export function parseHeartbeat(text: string): Heartbeat | null {
  let v: unknown
  try {
    v = JSON.parse(text)
  } catch {
    return null
  }
  if (typeof v !== 'object' || v === null) return null
  const o = v as Record<string, unknown>
  if (typeof o.id !== 'string' || typeof o.name !== 'string' || typeof o.at !== 'number') return null
  const state = STATES.find(s => s === o.state) ?? 'idle'
  return {
    id: o.id,
    name: o.name,
    model: typeof o.model === 'string' ? o.model : '',
    account: o.account === 2 ? 2 : 1,
    tokens: typeof o.tokens === 'number' ? o.tokens : 0,
    window: typeof o.window === 'number' && o.window > 0 ? o.window : 1_000_000,
    state,
    activity: typeof o.activity === 'string' ? o.activity : '',
    at: o.at,
    // The optional fields travel too: without them another session's row loses its project and dot color.
    ...(typeof o.project === 'string' ? { project: o.project } : {}),
    ...(typeof o.color === 'string' && /^(#[0-9a-fA-F]{6})?$/.test(o.color) ? { color: o.color } : {}),
  }
}

export function isStale(h: Pick<Heartbeat, 'at'>, now: number, staleMs: number): boolean {
  return now - h.at > staleMs
}

/**
 * Live sessions, stable order (name, then id). Entries older than staleMs are "gone"
 * and left out; the caller deletes the file once it is twice that old.
 */
export function liveSessions(all: readonly Heartbeat[], now: number, staleMs: number): Heartbeat[] {
  return all
    .filter(h => !isStale(h, now, staleMs))
    .sort((a, b) => a.name.localeCompare(b.name, 'en', { numeric: true }) || a.id.localeCompare(b.id))
}

/** Account from a CLAUDE_CONFIG_DIR value: ~/.claude-acct2 style dirs end in the account number; none = 1. */
export function accountFromConfigDir(dir: string | undefined): number {
  if (dir === undefined || dir === '') return 1
  const m = /acct(\d+)\/?$/.exec(dir)
  return m ? Number(m[1]) : 1
}

/** The value after `--name` in a claude command line, quoted or not. */
export function nameFromArgs(args: string): string | undefined {
  const m = /--name[= ]+(?:"([^"]+)"|'([^']+)'|(\S+))/.exec(args)
  return m ? (m[1] ?? m[2] ?? m[3]) : undefined
}

/** Last tool call description, trimmed to one line. */
export function oneLine(s: string, max = 120): string {
  const t = s.replace(/\s+/g, ' ').trim()
  return t.length > max ? `${t.slice(0, max - 1)}…` : t
}
