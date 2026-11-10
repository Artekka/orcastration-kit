import type { PluginOptions } from 'claude-code'

export type Config = {
  variant: 'band' | 'pane' | 'off'
  amberMark: number
  reportMark: number
  flashMs: number
  commitWarnPct: number
  commitCritPct: number
  commitCmd: string
  commitMs: number
  mounts: string[]
  /** Session names that draw the HUD; empty means every session. Hidden sessions still write heartbeats. */
  showForNames: string[]
  statusDir: string
  sessionName: string
  refreshMs: number
  staleMs: number
  cpuRedLoad: number
  quietFlagFile: string
  quietStatusCmd: string
  quietOnCmd: string
  quietOffCmd: string
  /** The file (relative to the session directory, or absolute) the on/off commands need; the chip is hidden without it. Empty skips the check. */
  quietRequiresFile: string
  /** What a session row's dot shows: its Claude account (blue/purple) or its project's color. */
  dotMode: 'account' | 'project'
  /** Items switched off, by id (README: Items). */
  hide: Set<string>
  /** The kit's runtime dir: the launcher records each project's tab color there (tab-colors). */
  kitRuntimeDir: string
}

const num = (v: unknown, d: number, min = 0): number =>
  typeof v === 'number' && Number.isFinite(v) && v >= min ? v : d
const str = (v: unknown, d = ''): string => (typeof v === 'string' ? v : d)

/** Options arrive typed by the manifest, but a hand-edited settings file can hold anything: clamp, never throw. */
export function parseConfig(o: PluginOptions, home: string): Config {
  const variant = str(o.variant, 'band')
  const dir = str(o.statusDir).trim()
  return {
    variant: variant === 'pane' || variant === 'off' ? variant : 'band',
    amberMark: num(o.contextAmberMark, 300_000),
    reportMark: num(o.contextReportMark, 350_000),
    flashMs: num(o.flashSeconds, 6) * 1000,
    commitWarnPct: num(o.commitWarnPct, 85),
    commitCritPct: num(o.commitCritPct, 95),
    commitCmd: str(o.commitCmd),
    commitMs: Math.max(5, num(o.commitSeconds, 30)) * 1000,
    mounts: str(o.mounts, '/').split(',').map(s => s.trim()).filter(Boolean),
    showForNames: str(o.showForNames, 'Orca').split(',').map(s => s.trim()).filter(Boolean),
    statusDir: dir === '' ? `${home}/.claude-status-hud` : dir.replace(/^~(?=\/|$)/, home),
    sessionName: str(o.sessionName).trim(),
    refreshMs: Math.max(1, num(o.refreshSeconds, 3)) * 1000,
    staleMs: Math.max(10, num(o.staleSeconds, 120)) * 1000,
    cpuRedLoad: num(o.cpuRedLoad, 0),
    quietFlagFile: str(o.quietModeFlagFile).trim().replace(/^~(?=\/|$)/, home),
    quietStatusCmd: str(o.quietModeStatusCmd).trim(),
    quietOnCmd: str(o.quietModeOnCmd).trim(),
    quietOffCmd: str(o.quietModeOffCmd).trim(),
    quietRequiresFile: str(o.quietModeRequiresFile, 'scripts/quiet-mode.sh').trim(),
    dotMode: str(o.dotMode, 'account') === 'project' ? 'project' : 'account',
    hide: new Set(str(o.hideItems).split(',').map(s => s.trim().toLowerCase()).filter(Boolean)),
    kitRuntimeDir: (str(o.kitRuntimeDir).trim() || '~/.orchestration-kit/runtime').replace(/^~(?=\/|$)/, home),
  }
}
