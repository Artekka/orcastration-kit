import { expect, test } from 'claude-code/testing'

import { world } from './world'

const START = { cwd: '/x', surface: 'terminal', isInteractive: true } as never
const BAND = { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 180 } as never
const QUIET = { quietModeOnCmd: 'bash g.sh on', quietModeOffCmd: 'bash g.sh off', quietModeStatusCmd: 'false' }

test('every host spawn runs from the home directory, never the session\'s own', async ($, on) => {
  const w = world(on)
  await $.session.start(START)
  await w.clock.advance(3000)
  expect(w.ran.length).toBeGreaterThan(3)
  expect(w.cwds.every(c => c === '/home/u')).toBe(true)
})

test('after a heartbeat spawn that cannot start, the next tick writes the file', async ($, on) => {
  const w = world(on)
  w.noStart.add('sh')
  await $.session.start(START)
  await w.clock.advance(500)
  expect(w.files.has('/home/u/.claude-status-hud/sessions/sess-1234567.json')).toBe(false)
  w.noStart.delete('sh')
  await w.clock.advance(3000)
  expect(w.files.has('/home/u/.claude-status-hud/sessions/sess-1234567.json')).toBe(true)
})

test('the quiet chip\'s command runs in the session\'s directory, where its script is; every other spawn from home', { options: QUIET }, async ($, on) => {
  const w = world(on)
  w.files.set('/x/scripts/quiet-mode.sh', '')
  await $.session.start(START)
  await w.clock.advance(500)
  const band = await $.ui.mount({ plugin: 'status-hud', surface: 'terminal', component: 'AbovePrompt', props: BAND })
  await band.press({ key: 'p-quiet' })
  const i = w.ran.findIndex(a => a[2] === 'bash g.sh on')
  expect(i).toBeGreaterThanOrEqual(0)
  expect(w.cwds[i]).toBe('/x')
  expect(w.cwds.filter((c, j) => j !== i).every(c => c === '/home/u')).toBe(true)
})
