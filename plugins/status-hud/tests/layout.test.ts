import { expect, test } from 'claude-code/testing'

import { parseConfig } from '../lib/config'
import { chips, drawBand, drawPane, lineText, modelBadge, sessionRow, spin, type Line, type View } from '../lib/layout'
import type { Heartbeat, Snapshot } from '../types'

const S = (name: string, k: number, state: Heartbeat['state'] = 'busy', account = 1): Heartbeat => ({ id: name, name, model: 'opus', account, tokens: k * 1000, window: 1_000_000, state, activity: 'doing a long thing that should truncate rather than wrap', at: 0 })
const sessions = ['Orca', 'Vali', 'Vali2', 'Vali4', 'Sib3', 'Sib5', 'Sib10', 'Sib11', 'Sib12', 'Sib13'].map((n, i) => S(n, 90 + i * 30, 'busy', i % 3 === 0 ? 2 : 1))
const snap: Snapshot = {
  now: 1_000, selfId: 'Orca', sessions, quietMode: false,
  host: {
    at: 0, threads: 28, load: [28.3, 28, 27], ramUsedGb: 15.6, ramTotalGb: 62, gpu: { util: 9, vramUsedGb: 11.8, vramTotalGb: 32.6, tempC: 44 },
    disks: [{ mount: '/', usedGb: 818, totalGb: 1007 }, { mount: '/data', usedGb: 900, totalGb: 2000 }],
    commit: { usedPct: 88, limitGb: 127, usedGb: 112, at: 0 },
    hist: { load: [20, 25, 30], ram: [10, 12], gpu: [1, 5] },
  },
}
const cfg = parseConfig({ quietModeOnCmd: 'a', quietModeOffCmd: 'b' }, '/h')
const view = (o: Partial<View> = {}): View => ({ snap, cfg, flash: {}, sel: 0, now: 1_000, ...o })
const widthOf = (l: Line): number => Array.from(lineText(l)).length

test('variant A: 10 rows at 180 columns, every line exactly the width, never wider', async () => {
  const lines = drawBand(view(), 180, 10)
  expect(lines.length).toBe(10)
  for (const l of lines) expect(widthOf(l)).toBe(180)
})

test('variant A degrades: narrower terminals truncate, short ones fall back to 3 rows, nothing exceeds the width', async () => {
  for (const cols of [150, 120, 100, 89, 60, 30]) {
    const lines = drawBand(view(), cols, 10)
    for (const l of lines) expect(widthOf(l)).toBeLessThanOrEqual(cols)
  }
  expect(drawBand(view(), 100, 10).length).toBe(10)
  expect(drawBand(view(), 80, 10).length).toBe(3)
  expect(drawBand(view(), 180, 6).length).toBe(3)
  expect(lineText(drawBand(view(), 100, 10)[6] as Line)).toContain('more')
})

test('variant C: about 60 columns, lines fit, every session row is a press target', async () => {
  const lines = drawPane(view(), 60)
  for (const l of lines) expect(widthOf(l)).toBeLessThanOrEqual(60)
  const targets = lines.flatMap(l => l.map(s => s.press)).filter((p): p is string => p !== undefined && p.startsWith('sel:'))
  expect(targets.length).toBe(10)
  for (const w of [30, 44, 80]) for (const l of drawPane(view(), w)) expect(widthOf(l)).toBeLessThanOrEqual(w)
})

test('thresholds color the session row: green, amber, red', async () => {
  const col = (k: number): string => sessionRow(view(), S('X', k), 70).runs(0).find(r => r.text.includes('K'))?.fg ?? ''
  const [g, a, r] = [col(100), col(310), col(360)]
  expect(new Set([g, a, r]).size).toBe(3)
  expect(col(300)).toBe(a)
  expect(col(349)).toBe(a)
  expect(col(350)).toBe(r)
})

test('the flash paints the crossing session red on one blink phase and not the other', async () => {
  const bgs = (now: number): (string | null)[] => sessionRow(view({ now, flash: { X: 5_000 } }), S('X', 360), 70).runs(0).map(r => r.bg)
  expect(bgs(0).includes('#6a1c22')).toBe(true)
  expect(bgs(500).includes('#6a1c22')).toBe(false)
  expect(sessionRow(view({ now: 6_000, flash: { X: 5_000 } }), S('X', 360), 70).runs(0).some(r => r.bg === '#6a1c22')).toBe(false)
})

test('chips: quiet mode (clickable only when both commands are set), commit warning, over-mark sessions', async () => {
  const labels = (v: View) => chips(v).map(c => c.label.trim())
  const c = chips(view())
  expect(c[0]?.press).toBe('quiet')
  expect(labels(view()).some(l => l.includes('Windows commit 88%'))).toBe(true)
  expect(labels(view()).some(l => l.startsWith('≥350K'))).toBe(true)
  expect(chips(view({ cfg: parseConfig({}, '/h') }))[0]?.press).toBe(undefined)
  expect(chips(view({ snap: { ...snap, quietMode: null } })).some(x => x.label.includes('mode'))).toBe(false)
  const calm = { ...snap, host: { ...snap.host!, commit: { ...snap.host!.commit!, usedPct: 40 } } }
  expect(chips(view({ snap: calm })).some(x => x.label.includes('commit'))).toBe(false)
})

// ---- ----------------------------------------------------------------------------------------------------

const labelsOf = (v: View): string[] => chips(v).map(c => c.label.trim())
const hasMode = (v: View): boolean => labelsOf(v).some(l => l.includes('mode'))

test('chip visibility: hidden when the toggle script is missing, unless quiet mode is already ON', () => {
  expect(hasMode(view({ snap: { ...snap, quietAvail: false } }))).toBe(false)
  expect(hasMode(view({ snap: { ...snap, quietAvail: true } }))).toBe(true)
  expect(hasMode(view({ snap: { ...snap, quietAvail: undefined } }))).toBe(true)
  const on = chips(view({ snap: { ...snap, quietMode: true, quietAvail: false } }))
  expect(on[0]?.label).toContain('QUIET mode')
  expect(on[0]?.press).toBe('quiet')
})

test('a failed press paints a red "failed" chip until the error expires, and it stays pressable', () => {
  const err = { wanted: true, msg: 'exit 127', until: 61_000 }
  const c = chips(view({ snap: { ...snap, quietErr: err }, now: 2_000 }))[0]!
  expect(c.label).toContain('✖ failed')
  expect(c.label).toContain('QUIET')
  expect(c.bg).toBe('#6a1c22')
  expect(c.press).toBe('quiet')
  const off = chips(view({ snap: { ...snap, quietErr: { ...err, wanted: false } }, now: 2_000 }))[0]!
  expect(off.label).toContain('WORK')
  expect(off.label).toContain('✖ failed')
  const gone = chips(view({ snap: { ...snap, quietErr: err }, now: 61_000 }))[0]!
  expect(gone.label).not.toContain('failed')
  expect(gone.label).toContain('WORK mode')
})

test('an error on a chip the visibility rule hides does not resurrect it', () => {
  expect(hasMode(view({ snap: { ...snap, quietAvail: false, quietErr: { wanted: true, msg: 'x', until: 99_000 } } }))).toBe(false)
})

test('the pane explains the chip in one caption line; the band does not spend a row on it', () => {
  const pane = drawPane(view(), 60).map(l => lineText(l).trim()).join(' ')
  expect(pane).toContain('QUIET holds NEW test/gate runs while you use the machine; running ones finish')
  expect(drawBand(view(), 180, 10).map(lineText).join('\n')).not.toContain('holds NEW')
  const hidden = drawPane(view({ snap: { ...snap, quietAvail: false } }), 60).map(lineText).join('\n')
  expect(hidden).not.toContain('holds NEW')
})

test('model badge after the name: OPS yellow, SNT blue, HKU green, GEM purple, else three letters in gray', async () => {
  expect(modelBadge('claude-opus-5-5[1m]')).toEqual(['OPS', '#e8b030'])
  expect(modelBadge('claude-sonnet-5-5')).toEqual(['SNT', '#4cd0e0'])
  expect(modelBadge('claude-haiku-5-5')).toEqual(['HKU', '#4fd160'])
  expect(modelBadge('gemini-3.8-flash')).toEqual(['GEM', '#b98cf0'])
  expect(modelBadge('claude-fable-5-1')).toEqual(['FAB', '#8a9bb0'])
  expect(modelBadge('')).toEqual(['   ', '#8a9bb0'])
  const row = (model: string, w: number): string => sessionRow(view(), { ...S('Orca', 100), model }, w).runs(0).map(r => r.text).join('')
  expect(row('claude-sonnet-5-5', 70)).toMatch(/Orca +SNT/)
  expect(row('opus', 70)).toMatch(/Orca +OPS/)
  const badge = sessionRow(view(), { ...S('Orca', 100), model: 'opus' }, 70).runs(0).find(r => r.text.includes('OPS'))
  expect(badge?.fg).toBe('#e8b030')
  expect(row('opus', 28)).not.toContain('OPS')   // too narrow: the badge gives way first
  for (const cols of [180, 120, 100]) for (const l of drawBand(view(), cols, 10)) expect(widthOf(l)).toBeLessThanOrEqual(cols)
})

test('a busy session\'s mark turns clockwise, one step per half second; shell and idle stay still', async () => {
  expect([0, 500, 1_000, 1_500, 2_000].map(spin)).toEqual(['▘', '▝', '▗', '▖', '▘'])
  const mark = (state: Heartbeat['state'], now: number): string => sessionRow(view({ now }), S('X', 100, state), 70).runs(0).map(r => r.text).join('')
  expect(mark('busy', 0)).toContain('▘')
  expect(mark('busy', 500)).toContain('▝')
  expect(mark('busy', 500)).not.toContain('▘')
  expect(mark('shell', 0)).toBe(mark('shell', 500))
  expect(mark('idle', 0)).toBe(mark('idle', 500))
})

test('the band\'s key says what the state marks mean', async () => {
  const key = lineText(drawBand(view(), 180, 10)[1] as Line)
  expect(key).toContain('▘ busy')
  expect(key).toContain('$ shell')
  expect(key).toContain('○ idle')
  for (const cols of [120, 100]) for (const l of drawBand(view(), cols, 10)) expect(widthOf(l)).toBeLessThanOrEqual(cols)
})
