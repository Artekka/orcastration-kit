import { expect, test } from 'claude-code/testing'

import { parseConfig } from '../lib/config'
import { accountFromConfigDir, isStale, liveSessions, nameFromArgs, oneLine, parseHeartbeat, serializeHeartbeat } from '../lib/heartbeat'
import { newTickState, sessionsDir, tick } from '../lib/tick'
import type { Heartbeat } from '../types'
import { SAMPLE_OUT, fakeIo } from './fakeio'

const hb = (o: Partial<Heartbeat> = {}): Heartbeat => ({ id: 'a', name: 'Sib3', model: 'opus', account: 1, tokens: 1000, window: 1_000_000, state: 'busy', activity: 'x', at: 1000, ...o })
const cfg = parseConfig({ statusDir: '/s', staleSeconds: 120, commitCmd: '' }, '/home/u')

test('heartbeat round-trips and a torn or foreign file is skipped, not thrown', async () => {
  expect(parseHeartbeat(serializeHeartbeat(hb()))).toEqual(hb())
  expect(parseHeartbeat('{"id":"a","na')).toBe(null)
  expect(parseHeartbeat('[]')).toBe(null)
  expect(parseHeartbeat('{"id":"a"}')).toBe(null)
  expect(parseHeartbeat('{"id":"a","name":"n","at":5,"state":"weird","account":9}')?.state).toBe('idle')
  // Another session's project and dot color survive the read (its row is drawn from them); a bad color is dropped.
  const full = hb({ project: 'my-app', color: '#16a085' })
  expect(parseHeartbeat(serializeHeartbeat(full))).toEqual(full)
  expect(parseHeartbeat(serializeHeartbeat(hb({ color: 'red;evil' })))?.color).toBe(undefined)
})

test('staleness: older than the limit is gone', async () => {
  expect(isStale({ at: 1000 }, 1000 + 120_000, 120_000)).toBe(false)
  expect(isStale({ at: 1000 }, 1001 + 120_000, 120_000)).toBe(true)
  const live = liveSessions([hb({ id: 'b', name: 'Vali', at: 500_000 }), hb({ id: 'a', name: 'Sib10', at: 1000 }), hb({ id: 'c', name: 'Sib3', at: 500_000 })], 500_000, 120_000)
  expect(live.map(h => h.name)).toEqual(['Sib3', 'Vali'])
})

test('identity helpers: --name, account from CLAUDE_CONFIG_DIR', async () => {
  expect(nameFromArgs('claude --name Sib12 --model opus[1m]')).toBe('Sib12')
  expect(nameFromArgs('claude --name "Orca Seat" x')).toBe('Orca Seat')
  expect(nameFromArgs('claude --resume')).toBe(undefined)
  expect(accountFromConfigDir('/home/u/.claude-acct2')).toBe(2)
  expect(accountFromConfigDir(undefined)).toBe(1)
  expect(accountFromConfigDir('/home/u/.claude')).toBe(1)
  expect(oneLine('a\n  b   c', 4)).toBe('a b…')
})

test('tick: writes own heartbeat, reads peers, drops stale, sweeps the long dead', async () => {
  const f = fakeIo({ now: 10_000_000, runs: a => (a[0] === 'sh' ? { exitCode: 0, stdout: SAMPLE_OUT } : undefined) })
  const put = (id: string, h: Heartbeat, mtime: number) => void f.files.set(`${sessionsDir(cfg)}/${id}.json`, { text: serializeHeartbeat(h), mtimeMs: mtime })
  put('peer', hb({ id: 'peer', name: 'Vali', at: 9_990_000 }), 9_990_000)
  put('stale', hb({ id: 'stale', name: 'Old', at: 9_800_000 }), 9_800_000)
  put('dead', hb({ id: 'dead', name: 'Dead', at: 9_000_000 }), 9_000_000)
  f.files.set(`${sessionsDir(cfg)}/torn.json`, { text: '{"id"', mtimeMs: 9_999_000 })
  const snap = await tick(f.io, cfg, hb({ id: 'me', name: 'Sib12', at: 0 }), newTickState(), async () => false)
  expect(snap.sessions.map(s => s.name)).toEqual(['Sib12', 'Vali'])
  expect(f.files.has(`${sessionsDir(cfg)}/dead.json`)).toBe(false)
  expect(f.files.has(`${sessionsDir(cfg)}/stale.json`)).toBe(true)
  expect(JSON.parse(f.files.get(`${sessionsDir(cfg)}/me.json`)?.text ?? '{}').at).toBe(10_000_000)
  expect(snap.host?.threads).toBe(28)
  expect(snap.quietMode).toBe(null)
})

test('tick: crossing the report mark sets a flash until now + flashSeconds, once', async () => {
  const f = fakeIo({ now: 5_000_000, runs: a => (a[0] === 'sh' ? { exitCode: 0, stdout: SAMPLE_OUT } : undefined) })
  const ts = newTickState()
  const c = parseConfig({ statusDir: '/s', commitCmd: '', flashSeconds: 6 }, '/h')
  await tick(f.io, c, hb({ id: 'me', tokens: 349_000 }), ts, async () => false)
  expect(ts.flash).toEqual({})
  f.setNow(5_003_000)
  await tick(f.io, c, hb({ id: 'me', tokens: 351_000 }), ts, async () => false)
  expect(ts.flash.me).toBe(5_003_000 + 6000)
  f.setNow(5_004_000)
  await tick(f.io, c, hb({ id: 'me', tokens: 352_000 }), ts, async () => false)
  expect(ts.flash.me).toBe(5_003_000 + 6000)
  f.setNow(5_010_000)
  await tick(f.io, c, hb({ id: 'me', tokens: 353_000 }), ts, async () => false)
  expect(ts.flash.me).toBe(undefined)
})

test('flashSeconds 0 disables the flash', async () => {
  const f = fakeIo({ runs: a => (a[0] === 'sh' ? { exitCode: 0, stdout: SAMPLE_OUT } : undefined) })
  const ts = newTickState()
  const c = parseConfig({ statusDir: '/s', commitCmd: '', flashSeconds: 0 }, '/h')
  await tick(f.io, c, hb({ id: 'me', tokens: 100 }), ts, async () => false)
  await tick(f.io, c, hb({ id: 'me', tokens: 400_000 }), ts, async () => false)
  expect(ts.flash).toEqual({})
})

// ---- ----------------------------------------------------------------------------------------------------

test('tick: quietAvail follows the toggle script in the session directory', async () => {
  const f = fakeIo({ now: 10_000_000, runs: a => (a[0] === 'sh' ? { exitCode: 0, stdout: SAMPLE_OUT } : undefined) })
  const c = parseConfig({ statusDir: '/s', commitCmd: '', quietModeOnCmd: 'a', quietModeOffCmd: 'b', quietModeFlagFile: '/f/q' }, '/h')
  const there = await tick(f.io, c, hb({ id: 'me' }), newTickState(), async p => p === '/proj/scripts/quiet-mode.sh', '/proj')
  expect(there.quietAvail).toBe(true)
  const missing = await tick(f.io, c, hb({ id: 'me' }), newTickState(), async () => false, '/proj')
  expect(missing.quietAvail).toBe(false)
})

test('tick: a recorded press failure rides the snapshot until it expires, then is dropped', async () => {
  const f = fakeIo({ now: 10_000_000, runs: a => (a[0] === 'sh' ? { exitCode: 0, stdout: SAMPLE_OUT } : undefined) })
  const c = parseConfig({ statusDir: '/s', commitCmd: '' }, '/h')
  const ts = newTickState()
  ts.quietErr = { wanted: true, msg: 'exit 2', until: 10_030_000 }
  expect((await tick(f.io, c, hb({ id: 'me' }), ts, async () => false)).quietErr).toEqual({ wanted: true, msg: 'exit 2', until: 10_030_000 })
  f.setNow(10_030_000)
  expect((await tick(f.io, c, hb({ id: 'me' }), ts, async () => false)).quietErr).toBe(null)
  expect(ts.quietErr).toBe(null)
})
