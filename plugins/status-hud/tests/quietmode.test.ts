import { expect, test } from 'claude-code/testing'

import { parseConfig } from '../lib/config'
import { canToggle, QUIET_ERR_MS, quietAvailable, quietModeOn, quietNote, toggleQuietMode } from '../lib/quietmode'
import { fakeIo } from './fakeio'

const withCmds = parseConfig({ quietModeOnCmd: 'bash g.sh on', quietModeOffCmd: 'bash g.sh off', quietModeFlagFile: '/f/quiet-mode' }, '/h')

test('the toggle asks for the opposite state and runs the configured command (mocked)', async () => {
  const f = fakeIo()
  const off = await toggleQuietMode(f.io, withCmds, false)
  expect(off).toEqual({ ran: true, wanted: true, ok: true })
  expect(f.calls[0]).toEqual(['sh', '-c', 'bash g.sh on'])
  const on = await toggleQuietMode(f.io, withCmds, true)
  expect(on.wanted).toBe(false)
  expect(f.calls[1]).toEqual(['sh', '-c', 'bash g.sh off'])
})

test('a failing command is reported, an unconfigured toggle runs nothing', async () => {
  const f = fakeIo({ runs: () => ({ exitCode: 2, stdout: '' }) })
  expect((await toggleQuietMode(f.io, withCmds, false)).ok).toBe(false)
  const bare = parseConfig({}, '/h')
  const g = fakeIo()
  expect(canToggle(bare)).toBe(false)
  expect(await toggleQuietMode(g.io, bare, false)).toEqual({ ran: false, wanted: true, ok: false })
  expect(g.calls.length).toBe(0)
})

test('state comes from the flag file, else the status command, else it is hidden (null)', async () => {
  const f = fakeIo()
  expect(await quietModeOn(f.io, withCmds, async p => p === '/f/quiet-mode')).toBe(true)
  expect(await quietModeOn(f.io, withCmds, async () => false)).toBe(false)
  const byCmd = parseConfig({ quietModeStatusCmd: 'test -f x' }, '/h')
  const g = fakeIo({ runs: () => ({ exitCode: 1, stdout: '' }) })
  expect(await quietModeOn(g.io, byCmd, async () => true)).toBe(false)
  expect(await quietModeOn(f.io, parseConfig({}, '/h'), async () => true)).toBe(null)
})

test('a ~ in the quiet-mode flag file means home (the kit default is ~/.orcastration-kit/runtime/quiet-mode)', () => {
  expect(parseConfig({ quietModeFlagFile: '~/.orcastration-kit/runtime/quiet-mode' }, '/h').quietFlagFile).toBe('/h/.orcastration-kit/runtime/quiet-mode')
  expect(parseConfig({ quietModeFlagFile: '/abs/q' }, '/h').quietFlagFile).toBe('/abs/q')
  expect(parseConfig({ quietModeFlagFile: '~x/q' }, '/h').quietFlagFile).toBe('~x/q')
})

// ---- the chip shows only where it can work, says what it did, and a failed press stays visible -------------

test('quietModeRequiresFile defaults to the kit script; an empty value turns the check off', () => {
  expect(parseConfig({}, '/h').quietRequiresFile).toBe('scripts/quiet-mode.sh')
  expect(parseConfig({ quietModeRequiresFile: '' }, '/h').quietRequiresFile).toBe('')
  expect(parseConfig({ quietModeRequiresFile: ' tools/q.sh ' }, '/h').quietRequiresFile).toBe('tools/q.sh')
})

test('available = the toggle script exists in the session directory (relative paths resolve there)', async () => {
  const seen: string[] = []
  const has = (want: string) => async (p: string): Promise<boolean> => (seen.push(p), p === want)
  expect(await quietAvailable(withCmds, '/proj', has('/proj/scripts/quiet-mode.sh'))).toBe(true)
  expect(await quietAvailable(withCmds, '/other', has('/proj/scripts/quiet-mode.sh'))).toBe(false)
  expect(seen).toEqual(['/proj/scripts/quiet-mode.sh', '/other/scripts/quiet-mode.sh'])
  const abs = parseConfig({ quietModeOnCmd: 'a', quietModeOffCmd: 'b', quietModeRequiresFile: '/opt/q.sh' }, '/h')
  expect(await quietAvailable(abs, '/proj', has('/opt/q.sh'))).toBe(true)
})

test('available is true without a check: empty requires-file, or a status-only chip that cannot be pressed', async () => {
  const never = async (): Promise<boolean> => false
  const noCheck = parseConfig({ quietModeOnCmd: 'a', quietModeOffCmd: 'b', quietModeRequiresFile: '' }, '/h')
  expect(await quietAvailable(noCheck, '/proj', never)).toBe(true)
  const readOnly = parseConfig({ quietModeStatusCmd: 'true' }, '/h')
  expect(canToggle(readOnly)).toBe(false)
  expect(await quietAvailable(readOnly, '/proj', never)).toBe(true)
})

test('a failed run carries "exit N" plus the first output line; a good run carries no detail', async () => {
  const bad = fakeIo({ runs: () => ({ exitCode: 127, stdout: '\nbash: scripts/quiet-mode.sh: No such file or directory\nmore' }) })
  const r = await toggleQuietMode(bad.io, withCmds, false)
  expect(r).toEqual({ ran: true, wanted: true, ok: false, detail: 'exit 127: bash: scripts/quiet-mode.sh: No such file or directory' })
  const quiet = fakeIo({ runs: () => ({ exitCode: 3, stdout: '' }) })
  expect((await toggleQuietMode(quiet.io, withCmds, true)).detail).toBe('exit 3')
})

test('the press notes say plainly what quiet mode does and how to undo it', () => {
  expect(QUIET_ERR_MS).toBe(60_000)
  const on = quietNote(true)
  expect(on).toContain('new test/gate runs wait')
  expect(on).toContain('running ones finish')
  expect(on).toContain('Press again')
  expect(quietNote(false)).toContain('start normally')
})

test('with nothing on stdout the detail falls back to the first stderr line (a missing script says so on stderr)', async () => {
  const f = fakeIo({ runs: () => ({ exitCode: 127, stdout: '', stderr: '\nbash: scripts/quiet-mode.sh: No such file or directory\nmore' }) })
  expect((await toggleQuietMode(f.io, withCmds, false)).detail).toBe('exit 127: bash: scripts/quiet-mode.sh: No such file or directory')
  const both = fakeIo({ runs: () => ({ exitCode: 2, stdout: 'out line', stderr: 'err line' }) })
  expect((await toggleQuietMode(both.io, withCmds, false)).detail).toBe('exit 2: out line')
})
