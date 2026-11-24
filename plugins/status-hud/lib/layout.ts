import type { Heartbeat, Host, Snapshot } from '../types'
import type { Config } from './config'
import { C, type Col, type Run, Scr, bar, clamp, graph2, lpad, pad, spark, sprite, trunc } from './cells'
import { commitLevel, fillLevel, flashPhase, isFlashing, loadLevel, type Level } from './thresholds'
import { canToggle, QUIET_EXPLAIN } from './quietmode'

export type View = { snap: Snapshot; cfg: Config; flash: Record<string, number>; sel: number; now: number }
/** One drawn piece of a line; `press` makes it a Button (`quiet`, or `sel:<index>`). */
export type Seg = { runs: Run[]; press?: string }
export type Line = Seg[]

const LV: Record<Level, Col> = { ok: C.green, amber: C.amber, red: C.red }
const LVD: Record<Level, Col> = { ok: C.gD, amber: C.aD, red: C.rD }
const seg = (s: Scr, y: number, press?: string): Seg => (press ? { runs: s.runs(y), press } : { runs: s.runs(y) })
const one = (text: string, fg: Col, bg: Col | null = null, bold = false, press?: string): Seg => {
  const runs = [{ text, fg, bg, bold }]
  return press ? { runs, press } : { runs }
}
/** Word wrap to `n` columns (a single word longer than that is cut by the line's own truncation). */
function wrap(text: string, n: number): string[] {
  const out: string[] = []
  let cur = ''
  for (const w of text.split(' ')) {
    if (cur !== '' && cur.length + 1 + w.length > n) {
      out.push(cur)
      cur = w
    } else cur = cur === '' ? w : `${cur} ${w}`
  }
  return cur === '' ? out : [...out, cur]
}
export const kfmt = (t: number): string => `${Math.round(t / 1000)}K`
const gb = (v: number, d = 1): string => v.toFixed(d)

export type Chip = { label: string; fg: Col; bg: Col; press?: string }

/** Hidden when quiet mode is not configured, or when its script is missing here and it is not already ON (so an ON flag can still be turned off). */
const quietChipShown = (snap: Snapshot): boolean => snap.quietMode !== null && (snap.quietAvail !== false || snap.quietMode === true)

export function chips(v: View): Chip[] {
  const out: Chip[] = []
  const { snap, cfg } = v
  if (quietChipShown(snap)) {
    const on = snap.quietMode === true
    const tog = canToggle(cfg)
    // A failed press stays on the chip (red, still pressable to retry) until it expires or the next press works.
    const err = snap.quietErr && v.now < snap.quietErr.until ? snap.quietErr : null
    const name = err ? (err.wanted ? 'QUIET' : 'WORK') : on ? 'QUIET mode' : 'WORK mode'
    out.push({ label: ` ${name}${err ? ' ✖ failed' : ''}${tog ? ' ⏻' : ''} `, fg: err || on ? C.white : C.bg, bg: err ? C.rD : on ? C.orange : C.green, ...(tog ? { press: 'quiet' } : {}) })
  }
  const host = snap.host
  if (host?.commit) {
    const lv = commitLevel(host.commit.usedPct, cfg)
    if (lv !== 'ok') out.push({ label: ` ⚠ Windows commit ${Math.round(host.commit.usedPct)}% `, fg: C.white, bg: lv === 'red' ? C.rD : C.aD })
  }
  const over = snap.sessions.filter(s => s.tokens >= cfg.reportMark)
  if (over.length > 0) out.push({ label: ` ≥${kfmt(cfg.reportMark)}: ${over.map(s => s.name).join(' ')} `, fg: C.white, bg: C.rD })
  if (host && loadLevel(host.load[0], host.threads, cfg) === 'red') out.push({ label: ` load ${host.load[0].toFixed(1)} high `, fg: C.white, bg: C.rD })
  out.push({ label: ` ${snap.sessions.length} sessions `, fg: C.tx, bg: C.gray })
  return out
}

function chipLine(v: View, width: number, left: string, right: string): Line {
  const line: Line = [one(left, C.dim)]
  let used = left.length + right.length
  for (const c of chips(v)) {
    const w = c.label.length + 1
    if (used + w > width) break
    line.push(one(c.label, c.fg, c.bg, true, c.press), one(' ', C.tx))
    used += w
  }
  line.push(one(' '.repeat(Math.max(0, width - used)), C.tx), one(right, C.dim))
  return line
}

function meterRow(s: Scr, x: number, y: number, label: string, f: number, fg: Col, text: string, barW: number, textFg: Col = C.tx, mark = -1): void {
  s.put(x, y, pad(label, 5), C.steel)
  bar(s, x + 5, y, barW, f, fg, mark)
  s.put(x + 6 + barW, y, text, textFg, null, true)
}

type Meter = { label: string; f: number; fg: Col; text: string; textFg: Col; mark: number; hist?: { d: number[]; lo: number; hi: number } }

export function meters(v: View, max: number): Meter[] {
  const host = v.snap.host
  if (!host) return []
  const lv = loadLevel(host.load[0], host.threads, v.cfg)
  const out: Meter[] = []
  const cpuRed = v.cfg.cpuRedLoad > 0 ? v.cfg.cpuRedLoad : host.threads * 0.9
  out.push({ label: 'CPU', f: host.load[0] / (cpuRed / 0.9 || 1), fg: LV[lv], text: `${lpad(host.load[0].toFixed(1), 4)}/${host.threads}t`, textFg: LV[lv], mark: -1, hist: { d: host.hist.load, lo: 0, hi: Math.max(host.threads, 1) } })
  out.push({ label: 'RAM', f: host.ramUsedGb / host.ramTotalGb, fg: C.cyan, text: `${gb(host.ramUsedGb)}/${gb(host.ramTotalGb, 0)}G`, textFg: C.tx, mark: -1, hist: { d: host.hist.ram, lo: 0, hi: host.ramTotalGb } })
  if (host.commit) {
    const cl = commitLevel(host.commit.usedPct, v.cfg)
    out.push({ label: 'WIN', f: host.commit.usedPct / 100, fg: LV[cl], text: `${Math.round(host.commit.usedPct)}% commit`, textFg: LV[cl], mark: Math.round((v.cfg.commitWarnPct / 100) * 14) })
  }
  if (host.gpu) {
    out.push({ label: 'GPU', f: host.gpu.util / 100, fg: C.purple, text: `${lpad(String(Math.round(host.gpu.util)), 3)}% ${Math.round(host.gpu.tempC)}°C`, textFg: C.purple, mark: -1, hist: { d: host.hist.gpu, lo: 0, hi: 100 } })
    out.push({ label: 'VRAM', f: host.gpu.vramUsedGb / host.gpu.vramTotalGb, fg: C.purple, text: `${gb(host.gpu.vramUsedGb)}/${gb(host.gpu.vramTotalGb)}G`, textFg: C.purple, mark: -1 })
  }
  for (const d of host.disks) {
    const f = d.usedGb / d.totalGb
    const hot = f >= 0.9 ? C.red : f >= 0.8 ? C.amber : C.green
    const total = d.totalGb >= 1000 ? `${gb(d.totalGb / 1024)}T` : `${Math.round(d.totalGb)}G`
    const used = d.totalGb >= 1000 ? `${gb(d.usedGb / 1024)}` : `${Math.round(d.usedGb)}`
    out.push({ label: trunc(d.mount === '/' ? 'DISK' : (d.mount.split('/').pop() || d.mount).toUpperCase(), 5), f, fg: hot, text: `${used}/${total} ${Math.round(f * 100)}%`, textFg: hot, mark: -1 })
  }
  // Too many for the rows: drop disks beyond the first, then VRAM, before anything else.
  const drop = (pred: (m: Meter, i: number) => boolean): void => {
    const i = out.findIndex(pred)
    if (i >= 0) out.splice(i, 1)
  }
  const isDisk = (m: Meter): boolean => !['CPU', 'RAM', 'WIN', 'GPU', 'VRAM'].includes(m.label)
  while (out.length > max) {
    const firstDisk = out.findIndex(isDisk)
    const before = out.length
    drop((m, i) => isDisk(m) && i > firstDisk)
    if (out.length === before) drop(m => m.label === 'VRAM')
    if (out.length === before) out.pop()
  }
  return out
}

/** Model badge: OPS opus (yellow), SNT sonnet (blue), HKU haiku (green), GEM gemini (purple), else the id's first three letters (gray). */
export function modelBadge(model: string): [string, Col] {
  const m = model.toLowerCase()
  const map: Record<string, [string, Col]> = { opus: ['OPS', C.amber], sonnet: ['SNT', C.cyan], haiku: ['HKU', C.green], gemini: ['GEM', C.purple] }
  for (const f of Object.keys(map)) if (m.includes(f)) return map[f] as [string, Col]
  const first = m.replace(/^claude-/, '').split(/[-[ ]/)[0] ?? ''
  return [first.slice(0, 3).toUpperCase().padEnd(3), C.steel]
}

/** A busy session's mark turns clockwise through the four corners (▘ ▝ ▗ ▖), one step per half second. */
export const spin = (now: number): string => '▘▝▗▖'.charAt(Math.floor(now / 500) % 4)

/** One session row: acct dot, name, context bar + K, state glyph, activity. Flashes red after crossing the report mark. */
export function sessionRow(v: View, h: Heartbeat, w: number, selected = false): Scr {
  const s = new Scr(w, 1)
  const lv = fillLevel(h.tokens, v.cfg)
  const flashing = isFlashing(v.flash[h.id], v.now) && flashPhase(v.now)
  const bg = flashing ? C.rD : selected ? C.gray : null
  const fg = flashing ? C.white : LV[lv]
  for (let x = 0; x < w; x++) s.put(x, 0, ' ', C.tx, bg)
  const st = h.state === 'busy' ? [spin(v.now), C.green] : h.state === 'shell' ? ['$', C.orange] : ['○', C.dim]
  s.put(0, 0, '●', h.account === 2 ? C.purple : C.blue, bg)
  s.put(2, 0, pad(trunc(h.name, 7), 7), flashing ? C.white : h.state === 'idle' ? C.dim : C.tx, bg, true)
  let x = 10
  if (w >= 30) {
    const [b, c] = modelBadge(h.model)
    s.put(x, 0, b, flashing ? C.white : c, bg, true)
    x += 4
  }
  if (w >= 24) {
    const mark = Math.round((v.cfg.reportMark / h.window) * 8)
    bar(s, x, 0, 8, h.tokens / h.window, fg, mark)
    if (flashing) for (let i = 0; i < 8; i++) s.cells[0]![x + i]!.bg = bg
    x += 9
  }
  s.put(x, 0, `${lpad(kfmt(h.tokens), 5)}${lv === 'red' ? '!' : lv === 'amber' ? '~' : ' '}`, fg, bg, true)
  x += 7
  s.put(x, 0, st[0] as string, flashing ? C.white : (st[1] as Col), bg, true)
  x += 2
  if (w - x > 6) s.put(x, 0, trunc(h.activity, w - x), flashing ? C.white : C.dim, bg)
  return s
}

const acctSummary = (ss: readonly Heartbeat[]): string => {
  const a1 = ss.filter(s => s.account !== 2).length
  return `SESSIONS ${ss.length} · acct 1 ×${a1} · acct 2 ×${ss.length - a1}`
}

/** Variant A: the framed band, up to 10 rows at 180 columns; falls back to the 3-row compact form when narrow or short. */
export function drawBand(v: View, cols: number, maxRows: number): Line[] {
  const W = clamp(cols, 20, 200)
  if (W < 90 || maxRows < 10) return drawCompact(v, W)
  const ss = v.snap.sessions
  const LX = 47
  const s = new Scr(W, 10)
  const dim = C.dim
  s.put(0, 0, `┌${'─'.repeat(W - 2)}┐`, dim)
  s.put(LX, 0, '┬', dim)
  s.put(2, 0, ` HOST · ${v.snap.host?.threads ?? '?'} threads `, C.gold, null, true)
  s.put(LX + 2, 0, ` ${acctSummary(ss)} `, C.gold, null, true)
  const tag = ' STATUS HUD '
  s.put(W - 2 - tag.length, 0, tag, dim)
  for (let y = 1; y <= 6; y++) {
    s.put(0, y, '│', dim)
    s.put(LX, y, '│', dim)
    s.put(W - 1, y, '│', dim)
  }
  s.put(0, 7, `├${'─'.repeat(W - 2)}┤`, dim)
  s.put(LX, 7, '┴', dim)
  s.put(0, 9, `└${'─'.repeat(W - 2)}┘`, dim)

  const ms = meters(v, 6)
  ms.forEach((m, i) => {
    meterRow(s, 2, 1 + i, m.label, m.f, m.fg, m.text, 14, m.textFg, m.mark)
    if (m.hist && LX - 2 - 32 >= 8) spark(s, 34, 1 + i, m.hist.d, Math.min(12, LX - 36), m.hist.lo, m.hist.hi, m.fg)
  })
  if (!v.snap.host) s.put(2, 2, 'waiting for host reading…', dim)

  const rx = LX + 2
  const area = W - rx - 2
  const win = ss[0]?.window ?? 1_000_000
  s.put(rx, 1, `CONTEXT of ${win >= 1_000_000 ? `${win / 1_000_000}M` : kfmt(win)}`, dim)
  s.put(rx + 15, 1, '■', C.green)
  s.put(rx + 17, 1, `<${kfmt(v.cfg.amberMark)}`, dim)
  s.put(rx + 24, 1, '■', C.amber)
  s.put(rx + 26, 1, `${kfmt(v.cfg.amberMark)}-${kfmt(v.cfg.reportMark)}`, dim)
  s.put(rx + 37, 1, '■', C.red)
  s.put(rx + 39, 1, `≥${kfmt(v.cfg.reportMark)}`, dim)
  // The state key: what the mark after each session's tokens means (busy turns, see spin).
  let kx = rx + 39 + `≥${kfmt(v.cfg.reportMark)}`.length + 3
  for (const [mark, col, text] of [['▘', C.green, 'busy'], ['$', C.orange, 'shell'], ['○', C.dim, 'idle']] as const) {
    if (kx + mark.length + 1 + text.length > rx + area) break
    s.put(kx, 1, mark, col)
    kx = s.put(kx + mark.length + 1, 1, text, dim) + 2
  }
  const cap = Math.max(0, area)
  const colW = cap >= 126 ? Math.floor((cap - 2) / 2) : cap
  const nCols = cap >= 126 ? 2 : 1
  const slots = 5 * nCols
  const shown = ss.length > slots ? slots - 1 : ss.length
  for (let i = 0; i < shown; i++) {
    const r = sessionRow(v, ss[i] as Heartbeat, colW)
    const cx = rx + Math.floor(i / 5) * (colW + 2)
    const cy = 2 + (i % 5)
    r.cells[0]!.forEach((c, k) => {
      const row = s.cells[cy]
      if (row && cx + k < W - 1) row[cx + k] = c
    })
  }
  if (ss.length > slots) s.put(rx + (nCols - 1) * (colW + 2), 6, `+${ss.length - shown} more (/hud pane)`, dim)
  if (ss.length === 0) s.put(rx, 3, 'no sessions reporting yet', dim)

  const lines: Line[] = []
  for (let y = 0; y < 8; y++) lines.push([seg(s, y)])
  lines.push(chipLine(v, W, '│ ', '│'))
  lines.push([seg(s, 9)])
  return lines
}

/** Variant B form, used as the band's narrow/short fallback: meters, session pills, chips. */
export function drawCompact(v: View, W: number): Line[] {
  const s = new Scr(W, 2)
  let x = 1
  const host = v.snap.host
  for (const m of meters(v, 6)) {
    const need = m.label.length + 1 + 8 + 1 + m.text.length + 2
    if (x + need > W) break
    s.put(x, 0, m.label, C.steel)
    x += m.label.length + 1
    bar(s, x, 0, 8, m.f, m.fg, m.mark)
    x += 9
    x = s.put(x, 0, m.text, m.textFg, null, true) + 2
  }
  if (!host) s.put(1, 0, 'waiting for host reading…', C.dim)
  x = 1
  for (const h of v.snap.sessions) {
    const lv = fillLevel(h.tokens, v.cfg)
    const flashing = isFlashing(v.flash[h.id], v.now) && flashPhase(v.now)
    const bg = flashing ? C.rD : h.state === 'idle' ? C.gray : LVD[lv]
    const txt = ` ${trunc(h.name, 8)} ${kfmt(h.tokens)}${lv === 'red' ? '!' : ''} `
    const g = h.state === 'busy' ? spin(v.now) : h.state === 'shell' ? '$' : '○'
    if (x + txt.length + 4 > W) break
    s.put(x, 1, ' ', C.tx, bg)
    s.put(x + 1, 1, '●', h.account === 2 ? C.purple : C.blue, bg)
    s.put(x + 2, 1, txt, flashing ? C.white : h.state === 'idle' ? C.dim : LV[lv], bg, true)
    s.put(x + 2 + txt.length, 1, g, C.tx, bg, true)
    s.put(x + 3 + txt.length, 1, ' ', C.tx, bg)
    x += txt.length + 5
  }
  return [[seg(s, 0)], [seg(s, 1)], chipLine(v, W, ' ', '')]
}

const HELM = [
  '..H..........H..', '.HH..........HH.', '.HH..KKKKKK..HH.', '..HHKSSSSSSKHH..',
  '...KSLLSSSSSK...', '...KSLSSSSSSK...', '...KGGGGGGGGK...', '...KSSSKKSSSK...',
  '...KSSSKKSSDK...', '....KSSKKSSK....', '....KDS..SDK....', '.....KK..KK.....',
]
const PX: Record<string, Col> = { K: C.ol, S: C.steel, L: C.steelL, D: C.steelD, G: C.gold, H: C.bone }

const sep = (W: number, label: string): Line => {
  const s = new Scr(W, 1)
  s.put(0, 0, '─'.repeat(W), C.dim)
  if (label) s.put(1, 0, ` ${label} `, C.gold, null, true)
  return [seg(s, 0)]
}

/** Variant C: the taller pane (about 60 columns), sprite helm on top, every session a clickable row. */
export function drawPane(v: View, cols: number): Line[] {
  const W = clamp(cols, 30, 80)
  const host = v.snap.host
  const ss = v.snap.sessions
  const lines: Line[] = []
  const head = new Scr(W, 6)
  const showHelm = W >= 44
  if (showHelm) sprite(head, 1, 0, HELM, PX)
  const hx = showHelm ? 19 : 1
  head.put(hx, 0, 'STATUS HUD', C.gold, null, true)
  head.put(hx, 1, 'terminal status hud', C.steel)
  const d = new Date(v.now)
  const z = (n: number): string => String(n).padStart(2, '0')
  head.put(hx, 2, `${z(d.getHours())}:${z(d.getMinutes())}:${z(d.getSeconds())}`, C.dim)
  head.put(hx, 3, `${ss.length} sessions`, C.tx)
  for (let y = 0; y < 6; y++) lines.push([seg(head, y)])
  lines.push(sep(W, `HOST · ${host?.threads ?? '?'} threads`))
  const barW = clamp(W - 30, 8, 26)
  const ms = meters(v, 8)
  const m = new Scr(W, Math.max(1, ms.length))
  ms.forEach((x, i) => meterRow(m, 1, i, x.label, x.f, x.fg, x.text, barW, x.textFg, x.mark))
  if (!host) m.put(1, 0, 'waiting for host reading…', C.dim)
  for (let y = 0; y < m.h; y++) lines.push([seg(m, y)])
  if (host) {
    const g = new Scr(W, 3)
    g.put(1, 0, `LOAD HISTORY   avg ${host.load.map(x => x.toFixed(1)).join(' / ')}`, C.dim)
    graph2(g, 1, 1, host.hist.load, W - 2, 0, Math.max(host.threads, 1), LV[loadLevel(host.load[0], host.threads, v.cfg)])
    for (let y = 0; y < 3; y++) lines.push([seg(g, y)])
  }
  lines.push(sep(W, acctSummary(ss)))
  ss.forEach((h, i) => lines.push([seg(sessionRow(v, h, W - 2, i === v.sel), 0, `sel:${i}`)]))
  const cur = ss[clamp(v.sel, 0, Math.max(0, ss.length - 1))]
  if (cur) {
    const lv = fillLevel(cur.tokens, v.cfg)
    const t = new Scr(W, 3)
    t.put(1, 0, `▸ ${cur.name}`, C.gold, null, true)
    t.put(4 + cur.name.length, 0, `${cur.state} · ${kfmt(cur.tokens)} of ${kfmt(cur.window)} · acct ${cur.account} · ${cur.model}`, C.dim)
    t.put(1, 1, trunc(cur.activity, W - 2), C.tx)
    t.put(1, 2, `context ${Math.round((cur.tokens / cur.window) * 100)}% ${lv === 'red' ? '(report now)' : lv === 'amber' ? '(hand over soon)' : '(ok)'}`, LV[lv])
    for (let y = 0; y < 3; y++) lines.push([seg(t, y)])
  }
  lines.push(sep(W, 'MODE'))
  const cl = chips(v)
  let row: Line = [one(' ', C.tx)]
  let used = 1
  for (const c of cl) {
    const w = c.label.length + 1
    if (used + w > W && row.length > 1) {
      lines.push(row)
      row = [one(' ', C.tx)]
      used = 1
    }
    row.push(one(c.label, c.fg, c.bg, true, c.press), one(' ', C.tx))
    used += w
  }
  lines.push(row)
  if (quietChipShown(v.snap)) for (const t of wrap(QUIET_EXPLAIN, W - 2)) lines.push([one(` ${t}`, C.dim)])
  return lines
}

export const lineText = (l: Line): string => l.map(sg => sg.runs.map(r => r.text).join('')).join('')
export type { Host }
