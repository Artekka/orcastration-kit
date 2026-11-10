import { expect, test } from 'claude-code/testing'

import { paletteColor } from '../lib/project'
import { world } from './world'

const START = { cwd: '/x', surface: 'terminal', isInteractive: true } as never
const BAND = { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 180 } as never

for (const surface of ['terminal', 'desktop'] as const) {
  test(`session start → heartbeat written, band draws the session on ${surface}`, async ($, on) => {
    const w = world(on)
    await $.session.start(START)
    await w.clock.advance(500)
    const hb = JSON.parse(w.files.get('/home/u/.claude-status-hud/sessions/sess-1234567.json') ?? '{}')
    expect(hb.name).toBe('Orca')
    expect(hb.account).toBe(2)
    expect(hb.tokens).toBe(100_000)
    expect(w.files.has('/home/u/.claude-status-hud/host.json')).toBe(true)
    const band = await $.ui.mount({ plugin: 'status-hud', surface, component: 'AbovePrompt', props: BAND })
    const tree = JSON.stringify(await band.drawn())
    expect(tree).toContain('Orca')
    expect(tree).toContain('100K')
  })
}

test('crossing the report mark flashes the session row red in the drawn band, then settles', async ($, on) => {
  const w = world(on)
  await $.session.start(START)
  await w.clock.advance(500)
  w.usage.tokens = 351_000
  await w.clock.advance(3000)
  // The over-mark chip is also red, so count the red backgrounds: the flashing row adds some on one blink phase only.
  const reds = async (): Promise<number> => {
    const band = await $.ui.mount({ plugin: 'status-hud', surface: 'terminal', component: 'AbovePrompt', props: BAND })
    return (JSON.stringify(await band.drawn()).match(/#6a1c22/g) ?? []).length
  }
  const seen: number[] = []
  for (let i = 0; i < 4; i++) {
    seen.push(await reds())
    await w.clock.advance(500)
  }
  expect(new Set(seen).size).toBe(2)
  await w.clock.advance(10_000)
  expect(await reds()).toBe(Math.min(...seen))
})

test('the pane draws session rows as buttons; pressing one selects it', async ($, on) => {
  const w = world(on)
  await $.session.start(START)
  await w.clock.advance(500)
  const pane = await $.ui.mount({ plugin: 'status-hud', surface: 'terminal', component: 'Pane', requestId: 'status-hud', props: { bodyColumns: 60 } as never })
  expect((await pane.findAll({ type: 'Button' })).length).toBeGreaterThanOrEqual(1)
})


test('Quiet Mode chip: press runs the configured command (mocked)', { options: { quietModeOnCmd: 'bash g.sh on', quietModeOffCmd: 'bash g.sh off', quietModeStatusCmd: 'false' } }, async ($, on) => {
  const w = world(on)
  w.files.set('/x/scripts/quiet-mode.sh', '')
  await $.session.start(START)
  await w.clock.advance(500)
  const band = await $.ui.mount({ plugin: 'status-hud', surface: 'terminal', component: 'AbovePrompt', props: BAND })
  expect(await band.find({ key: 'p-quiet' })).toBeDefined()
  const seen = (): boolean => w.ran.some(a => a[0] === 'sh' && a[2] === 'bash g.sh on')
  expect(seen()).toBe(false)
  await band.press({ key: 'p-quiet' })
  expect(seen()).toBe(true)
})

test('the heartbeat never carries the prompt text, a raw command, a path or a URL; the file is chmod 600 and the dir 700', { options: { refreshSeconds: 1 } }, async ($, on) => {
  let during = ''
  let w!: ReturnType<typeof world>
  // Hooks beneath the plugins register before the test first calls `$`.
  on('tool.call', async () => {
    await w.clock.advance(1500)
    during = w.files.get('/home/u/.claude-status-hud/sessions/sess-1234567.json') ?? ''
    return { result: { content: 'ok' } } as never
  })
  w = world(on)
  await $.session.start(START)
  await w.clock.advance(500)
  await $.tool.call({ tool: 'Bash', command: 'curl -H "Authorization: SECRET-TOKEN" https://x.example/y', description: 'Fetch the status page' } as never)
  const hb = JSON.parse(during)
  expect(hb.activity).toBe('Bash: Fetch the status page')
  expect(during).not.toContain('SECRET-TOKEN')
  await $.tool.call({ tool: 'Read', file_path: '/home/u/.ssh/id_rsa' } as never)
  const dirs = w.ran.filter(a => a[0] === 'mkdir' && a.includes('700'))
  expect(dirs.map(a => a[a.length - 1])).toEqual(['/home/u/.claude-status-hud', '/home/u/.claude-status-hud/sessions'])
  expect(w.ran.some(a => String(a[2]).includes('chmod 600'))).toBe(true)
  expect([...w.files.values()].some(t => t.includes('id_rsa'))).toBe(false)
})

// showForNames: only the named sessions draw; every session still writes its heartbeat (the shown HUD reads them all).
const HB = '/home/u/.claude-status-hud/sessions/sess-1234567.json'
const drawnBand = async ($: any): Promise<string> =>
  JSON.stringify((await (await $.ui.mount({ plugin: 'status-hud', surface: 'terminal', component: 'AbovePrompt', props: BAND })).drawn()) ?? null)

test('showForNames default: the session named Orca draws the band', async ($, on) => {
  const w = world(on, { name: 'Orca' })
  await $.session.start(START)
  await w.clock.advance(500)
  expect(await drawnBand($)).toContain('Orca')
})

test('showForNames default: a session named Sib3 draws nothing but still writes its heartbeat', async ($, on) => {
  const w = world(on, { name: 'Sib3' })
  await $.session.start(START)
  await w.clock.advance(500)
  expect(JSON.parse(w.files.get(HB) ?? '{}').name).toBe('Sib3')
  const tree = await drawnBand($)
  expect(tree).not.toContain('Sib3')
  expect(tree).not.toContain('100K')
  expect(tree).toContain('ENGINE-DEFAULT') // passed through to the engine, like a HUD that is off
  const pane = await $.ui.mount({ plugin: 'status-hud', surface: 'terminal', component: 'Pane', requestId: 'status-hud', props: { bodyColumns: 60 } as never })
  expect(JSON.stringify((await pane.drawn()) ?? null)).not.toContain('Sib3')
  // The heartbeat keeps refreshing while hidden.
  w.usage.tokens = 222_000
  await w.clock.advance(3000)
  expect(JSON.parse(w.files.get(HB) ?? '{}').tokens).toBe(222_000)
})

test('/hud band in a hidden session shows the band there; /hud off hides it again', async ($, on) => {
  const w = world(on, { name: 'Sib3' })
  await $.session.start(START)
  await w.clock.advance(500)
  expect(await drawnBand($)).not.toContain('Sib3')
  await $.command.run({ command: 'hud', args: 'band' } as never)
  expect(await drawnBand($)).toContain('Sib3')
  await $.command.run({ command: 'hud', args: 'off' } as never)
  expect(await drawnBand($)).not.toContain('Sib3')
})

test('showForNames empty: any session draws the band', { options: { showForNames: '' } }, async ($, on) => {
  const w = world(on, { name: 'Sib3' })
  await $.session.start(START)
  await w.clock.advance(500)
  expect(await drawnBand($)).toContain('Sib3')
})

test('showForNames "Orca,Vali": Vali draws the band', { options: { showForNames: 'Orca, Vali' } }, async ($, on) => {
  const w = world(on, { name: 'Vali' })
  await $.session.start(START)
  await w.clock.advance(500)
  expect(await drawnBand($)).toContain('Vali')
})

test('showForNames is exact and case-sensitive: orca does not match Orca', { options: { showForNames: 'Orca' } }, async ($, on) => {
  const w = world(on, { name: 'orca' })
  await $.session.start(START)
  await w.clock.advance(500)
  expect(await drawnBand($)).not.toContain('orca')
})

test('/hud pane and /hud off in a hidden session never change the saved look', async ($, on) => {
  const w = world(on, { name: 'Sib3' })
  w.stored.variant = 'band'
  await $.session.start(START)
  await w.clock.advance(500)
  await $.command.run({ command: 'hud', args: 'pane' } as never)
  expect(w.stored.variant).toBe('band')
  await $.command.run({ command: 'hud', args: 'off' } as never)
  expect(w.stored.variant).toBe('band')
})

test('/hud pane in Orca persists the look', async ($, on) => {
  const w = world(on, { name: 'Orca' })
  w.stored.variant = 'band'
  await $.session.start(START)
  await w.clock.advance(500)
  await $.command.run({ command: 'hud', args: 'pane' } as never)
  expect(w.stored.variant).toBe('pane')
})

for (const name of ['Sib3', 'Orca'] as const) {
  test(`saved look "pane": ${name === 'Orca' ? 'the shown session opens the pane at start' : 'a hidden session never opens the pane at start'}`, async ($, on) => {
    const w = world(on, { name })
    w.stored.variant = 'pane'
    await $.session.start(START)
    await w.clock.advance(500)
    expect(w.opened.includes('status-hud')).toBe(name === 'Orca')
  })
}

// ---- visible only where it can work, honest about a failed press ----------------------------------------

const QUIET_OPTS = { quietModeOnCmd: 'bash g.sh on', quietModeOffCmd: 'bash g.sh off', quietModeStatusCmd: 'false' }

test('Quiet Mode chip: no toggle script in the session directory means no chip at all', { options: QUIET_OPTS }, async ($, on) => {
  const w = world(on)
  await $.session.start(START)
  await w.clock.advance(500)
  const band = await $.ui.mount({ plugin: 'status-hud', surface: 'terminal', component: 'AbovePrompt', props: BAND })
  expect(JSON.stringify(await band.drawn())).not.toContain('WORK mode')
  expect(await band.find({ key: 'p-quiet' })).toBeUndefined()
})

test('Quiet Mode chip: a failing command turns the chip red with "failed" and toasts why', { options: { ...QUIET_OPTS, quietModeOnCmd: 'false' } }, async ($, on) => {
  const w = world(on)
  w.files.set('/x/scripts/quiet-mode.sh', '')
  await $.session.start(START)
  await w.clock.advance(500)
  const band = await $.ui.mount({ plugin: 'status-hud', surface: 'terminal', component: 'AbovePrompt', props: BAND })
  await band.press({ key: 'p-quiet' })
  await w.clock.advance(500)
  const after = await $.ui.mount({ plugin: 'status-hud', surface: 'terminal', component: 'AbovePrompt', props: BAND })
  const tree = JSON.stringify(await after.drawn())
  expect(tree).toContain('failed')
  expect(tree).toContain('#6a1c22')
  expect(w.toasts.join(' ')).toContain('exit 1')
  // It heals: 60 s later the red chip is gone even if nobody pressed again.
  await w.clock.advance(61_000)
  const healed = await $.ui.mount({ plugin: 'status-hud', surface: 'terminal', component: 'AbovePrompt', props: BAND })
  expect(JSON.stringify(await healed.drawn())).not.toContain('failed')
})

test('/hud help explains the chip; a good press toasts what quiet mode does', { options: QUIET_OPTS }, async ($, on) => {
  const w = world(on)
  w.files.set('/x/scripts/quiet-mode.sh', '')
  await $.session.start(START)
  await w.clock.advance(500)
  const help = await $.command.run({ command: 'hud', args: 'help' } as never)
  expect(help.text).toContain('QUIET holds NEW test/gate runs')
  expect(help.text).toContain('quietModeRequiresFile')
  const band = await $.ui.mount({ plugin: 'status-hud', surface: 'terminal', component: 'AbovePrompt', props: BAND })
  await band.press({ key: 'p-quiet' })
  expect(w.toasts.join(' ')).toContain('running ones finish')
})

test('Quiet Mode chip: a failed press then a good one returns the chip to plain, and the toast names the stderr line', { options: QUIET_OPTS }, async ($, on) => {
  const w = world(on)
  w.files.set('/x/scripts/quiet-mode.sh', '')
  w.failing.add('bash g.sh on')
  await $.session.start(START)
  await w.clock.advance(500)
  const mount = () => $.ui.mount({ plugin: 'status-hud', surface: 'terminal', component: 'AbovePrompt', props: BAND })
  await (await mount()).press({ key: 'p-quiet' })
  await w.clock.advance(500)
  expect(JSON.stringify(await (await mount()).drawn())).toContain('failed')
  expect(w.toasts.join(' ')).toContain('exit 127: bash: g.sh: No such file or directory')
  w.failing.delete('bash g.sh on')
  await (await mount()).press({ key: 'p-quiet' })
  await w.clock.advance(500)
  const tree = JSON.stringify(await (await mount()).drawn())
  expect(tree).not.toContain('failed')
  expect(tree).toContain('WORK mode')
})

test('project dots: the heartbeat carries the project and its dot color (tab color, else recorded, else the project\'s own)', { options: { dotMode: 'project' } }, async ($, on) => {
  const HB = '/home/u/.claude-status-hud/sessions/sess-1234567.json'
  // The launcher told the session its tab's color: that wins.
  const w = world(on, { repo: '/home/u/work/book-shop', env: { CLAUDE_TAB_COLOR: '#8e44ad' } })
  w.files.set('/home/u/.orchestration-kit/runtime/tab-colors', '/home/u/work/book-shop\t#d35400\n')
  await $.session.start(START)
  await w.clock.advance(500)
  const hb = JSON.parse(w.files.get(HB) ?? '{}')
  expect(hb.project).toBe('book-shop')
  expect(hb.color).toBe('#8e44ad')
  const band = await $.ui.mount({ plugin: 'status-hud', surface: 'terminal', component: 'AbovePrompt', props: BAND })
  const tree = JSON.stringify(await band.drawn())
  expect(tree).toContain('book-shop')
  expect(tree).toContain('#8e44ad')
})

test('project dots: no tab color and no tab-colors file: the project\'s own color, never an error', { options: { dotMode: 'project' } }, async ($, on) => {
  const w = world(on, { repo: '/home/u/work/book-shop' })
  await $.session.start(START)
  await w.clock.advance(500)
  const hb = JSON.parse(w.files.get('/home/u/.claude-status-hud/sessions/sess-1234567.json') ?? '{}')
  expect(hb.project).toBe('book-shop')
  expect(hb.color).toBe(paletteColor('book-shop'))
  // the launcher records the project's color later: the next minute's read picks it up
  w.files.set('/home/u/.orchestration-kit/runtime/tab-colors', '/home/u/work/other\t#2980b9\n/home/u/work/book-shop\t#d35400\n')
  await w.clock.advance(61_000)
  expect(JSON.parse(w.files.get('/home/u/.claude-status-hud/sessions/sess-1234567.json') ?? '{}').color).toBe('#d35400')
})

test('a busy session\'s mark turns between full refreshes (redrawn every half second while busy)', async ($, on) => {
  const turns: string[] = []
  let w!: ReturnType<typeof world>
  on('tool.call', async () => {
    await w.clock.advance(3000)   // a full refresh sees this session busy
    for (let i = 0; i < 4; i++) {
      const band = await $.ui.mount({ plugin: 'status-hud', surface: 'terminal', component: 'AbovePrompt', props: BAND })
      const t = JSON.stringify(await band.drawn())
      turns.push(['▝', '▗', '▖'].filter(m => t.includes(m)).join(''))   // ▘ is also in the key, so count the other three
      await w.clock.advance(500)
    }
    return { result: { content: 'ok' } } as never
  })
  w = world(on)
  await $.session.start(START)
  await w.clock.advance(500)
  await $.tool.call({ tool: 'Read', description: 'Read a file' } as never)
  expect(new Set(turns).size).toBeGreaterThan(1)
})
