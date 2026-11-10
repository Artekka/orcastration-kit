// The setup page's data: the band drawn for a sample in which every item shows, and where each item sits.
// Each item is found by drawing the band again with only that item hidden: the first cell that changes is
// where its number goes, so the page follows the real layout code and never a hand-drawn picture.
// Usage (from the kit): bash scripts/hud-guide.sh build   — writes docs/status-hud-guide.html
import { parseConfig } from '../lib/config'
import { drawBand, type Line } from '../lib/layout'
import type { Heartbeat, Snapshot } from '../types'

export const COLS = 180

/** Every item, in the README's order, with a plain name and what it shows. `when` = only drawn sometimes. */
export const ITEMS: { id: string; area: string; name: string; what: string; when?: string }[] = [
  { id: 'host-title', area: 'Machine', name: 'Machine title', what: 'The heading of the machine box: how many processor threads this computer has.' },
  { id: 'cpu', area: 'Machine', name: 'CPU meter', what: 'How busy the processor is: the 1-minute load against the number of threads. Turns red near full.' },
  { id: 'history', area: 'Machine', name: 'History graphs', what: 'The small graphs to the right of the meters: the last few minutes of each reading.' },
  { id: 'ram', area: 'Machine', name: 'Memory (RAM)', what: 'Memory in use out of the total.' },
  { id: 'win', area: 'Machine', name: 'Windows memory limit', what: 'On WSL only: how much of the memory Windows can promise is promised. At 100% Windows stops WSL, and every session with it.', when: 'WSL only' },
  { id: 'gpu', area: 'Machine', name: 'Graphics card', what: 'How busy the graphics card is, and its temperature.', when: 'with an NVIDIA card' },
  { id: 'vram', area: 'Machine', name: 'Graphics memory', what: 'Memory on the graphics card in use out of the total.', when: 'with an NVIDIA card' },
  { id: 'disk', area: 'Machine', name: 'Main disk', what: 'Space used on the first drive in the mounts setting.' },
  { id: 'disk2', area: 'Machine', name: 'Other disks', what: 'Space used on any further drive in the mounts setting, when there is room for it.', when: 'with a second mount' },
  { id: 'sessions-title', area: 'Sessions', name: 'Sessions title', what: 'The heading of the sessions box: how many Claude sessions are running, and across how many accounts or projects.' },
  { id: 'context-key', area: 'Sessions', name: 'Context colour key', what: 'Explains the bar colours: green is fine, amber is filling up, red is past the point where a session should report.' },
  { id: 'dot-key', area: 'Sessions', name: 'Project key', what: 'With project dots: which colour is which project.', when: 'project dots' },
  { id: 'state-key', area: 'Sessions', name: 'Busy/idle key', what: 'Explains the mark after each session: ▘ busy (it turns while working), $ running a command, ○ idle.' },
  { id: 'dot', area: 'Sessions', name: 'Session dot', what: 'A coloured dot per session: its Claude account, or its project (the colour of its terminal tab when the launcher recorded one).' },
  { id: 'model', area: 'Sessions', name: 'Model badge', what: 'Which model the session runs: OPS (Opus, yellow), SNT (Sonnet, blue), HKU (Haiku, green), GEM (Gemini, purple).' },
  { id: 'bar', area: 'Sessions', name: 'Context bar', what: 'How full the session\'s context (its working memory) is, coloured by the key.' },
  { id: 'tokens', area: 'Sessions', name: 'Context number', what: 'The same fill as a number of tokens, e.g. 230K.' },
  { id: 'state', area: 'Sessions', name: 'Busy/idle mark', what: 'Whether the session is working (▘, turning), running a command ($), or waiting (○).' },
  { id: 'activity', area: 'Sessions', name: 'Last action', what: 'What the session did last.' },
  { id: 'column2', area: 'Sessions', name: 'Second column', what: 'With more than five sessions on a wide screen, a second column of rows (otherwise "+N more").', when: 'more than five sessions' },
  { id: 'frame-title', area: 'Sessions', name: 'STATUS HUD label', what: 'The name on the top-right corner of the frame.' },
  { id: 'work-mode', area: 'Bottom chips', name: 'Work/Quiet mode', what: 'A button: Quiet mode holds new test runs so the machine stays responsive; Work mode is normal.', when: 'with the kit\'s quiet-mode script' },
  { id: 'count', area: 'Bottom chips', name: 'Session count', what: 'How many sessions are reporting.' },
  { id: 'warnings', area: 'Bottom chips', name: 'Alerts', what: 'Chips at the right, most urgent first: Windows memory, a session past the report mark, a high load.', when: 'when something needs you' },
]

const S = (name: string, k: number, state: Heartbeat['state'], project: string, color: string, account: number, activity: string): Heartbeat =>
  ({ id: name, name, model: 'opus', account, tokens: k * 1000, window: 1_000_000, state, activity, at: 0, project, color })
const sessions = [
  S('Lead', 170, 'busy', 'my-app', '#16a085', 1, 'orchestrating · row 7 gate queued'),
  S('Mars', 64, 'busy', 'my-app', '#16a085', 1, 'row 6-3 settings page'),
  S('Venus', 362, 'busy', 'my-app', '#16a085', 2, 'row 7-7 final gate'),
  S('Vulcan', 231, 'shell', 'my-app', '#16a085', 2, 'npm test'),
  S('Apollo', 120, 'idle', 'my-app', '#16a085', 1, 'READ row 6-4'),
  S('Lotus', 95, 'busy', 'website', '#8e44ad', 1, 'editing index.html'),
  S('Finch', 40, 'idle', 'website', '#8e44ad', 2, 'Bash'),
]
const wave = (n: number, a: number, b: number, p: number): number[] => Array.from({ length: n }, (_, i) => a + b * Math.sin(i / p))
export const SNAP: Snapshot = {
  now: 0, selfId: 'Lead', sessions, quietMode: false,
  host: {
    at: 0, threads: 20, load: [18.6, 17.9, 16.2], ramUsedGb: 9.8, ramTotalGb: 16,
    gpu: { util: 31, vramUsedGb: 3.1, vramTotalGb: 8, tempC: 52 },
    disks: [{ mount: '/', usedGb: 410, totalGb: 1007 }, { mount: '/data', usedGb: 1200, totalGb: 2000 }],
    commit: { usedPct: 88, limitGb: 40, usedGb: 35, at: 0 },
    hist: { load: wave(60, 15, 4, 5), ram: wave(60, 9, 1, 7), gpu: wave(60, 30, 15, 3) },
  },
}

type Cell = [string, string, string, number] // char, fg, bg ('' = none), bold
const grid = (lines: Line[]): Cell[][] =>
  lines.map(l => l.flatMap(sg => sg.runs.flatMap(r => Array.from(r.text).map((ch): Cell => [ch, r.fg, r.bg ?? '', r.bold ? 1 : 0]))))
const draw = (opts: Record<string, string>): Cell[][] =>
  grid(drawBand({ snap: SNAP, cfg: parseConfig({ quietModeOnCmd: 'a', quietModeOffCmd: 'b', ...opts }, '/h'), flash: {}, sel: -1, now: 0 }, COLS, 10))
const same = (a: Cell | undefined, b: Cell | undefined): boolean => !!a && !!b && a.join('\u0000') === b.join('\u0000')

/** Where an item sits: per row it touches, the columns that are its own (the rest of the row only shifted). */
function locate(full: Cell[][], hidden: Cell[][]): { row: number; from: number; to: number }[] {
  const out: { row: number; from: number; to: number }[] = []
  for (let y = 0; y < full.length; y++) {
    const a = full[y] ?? [], b = hidden[y] ?? []
    let x = 0
    while (x < a.length && same(a[x], b[x])) x++
    if (x >= a.length) continue
    // The item's cells: the shortest span after which this row and the hidden row line up again.
    let to = a.length
    for (let k = 1; k <= 60 && x + k < a.length; k++) {
      let ok = true
      for (let j = 0; j < 8 && x + k + j < a.length; j++) if (!same(a[x + k + j], b[x + j])) { ok = false; break }
      if (ok) { to = x + k; break }
    }
    if (to === a.length) { to = x; while (to < a.length && !same(a[to], b[to])) to++ }
    out.push({ row: y, from: x, to })
  }
  return out
}

export function guideData(): { cols: number; account: Cell[][]; project: Cell[][]; items: (typeof ITEMS[number] & { at: { row: number; from: number; to: number }[] })[] } {
  const project = draw({ dotMode: 'project' })
  return {
    cols: COLS,
    account: draw({ dotMode: 'account' }),
    project,
    items: ITEMS.map(it => {
      // The project key goes with the dots, so the dots are found with the key already off; the second column
      // also changes the title's count, so its place is below the title.
      const base = it.id === 'dot' ? draw({ dotMode: 'project', hideItems: 'dot-key' }) : project
      let at = locate(base, draw({ dotMode: 'project', hideItems: it.id === 'dot' ? 'dot,dot-key' : it.id }))
      if (it.id === 'column2') at = at.filter(a => a.row > 0)
      // Rows below a removed meter move up, and a removed chip moves the rest: keep the rows that are the
      // item's own. Per-session items touch every session row; anything else is one row.
      const perRow = ['dot', 'bar', 'tokens', 'state', 'activity'].includes(it.id)
      if (!perRow) at = at.slice(0, 1)
      else at = at.filter(a => a.row >= 2 && a.row <= 6)
      return { ...it, at }
    }),
  }
}

if (process.argv[1]?.endsWith('guide.ts')) process.stdout.write(JSON.stringify(guideData()))
