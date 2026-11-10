import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Heartbeat, Snapshot } from '../types'
import { parseConfig, type Config } from '../lib/config'
import { accountFromConfigDir, nameFromArgs, oneLine } from '../lib/heartbeat'
import { projectColor, repoFromCommonDir } from '../lib/project'
import type { Io } from '../lib/io'
import { ensureStatusDirs } from '../lib/ensureDir'
import { newTickState, tick } from '../lib/tick'
import { QUIET_EXPLAIN, quietFailure, quietNote, toggleQuietMode } from '../lib/quietmode'
import { drawBand, drawPane, type Line, type View } from '../lib/layout'

const PANE = 'status-hud'
const snapA = atom({ plugin: 'status-hud', key: 'snap' } as const, null)
const flashA = atom({ plugin: 'status-hud', key: 'flash' } as const, {})
const selA = atom({ plugin: 'status-hud', key: 'sel' } as const, 0)
const variantA = atom({ plugin: 'status-hud', key: 'variant' } as const, null)

type Dollar = EngineInterface
type Table = { Box: any; Text: any; Button: any }

// Module-level on purpose: the validator only lets `$` flow into top-level functions, and a reload starts these over anyway.
const S: {
  cfg?: Config
  io?: Io
  exists?: (p: string) => Promise<boolean>
  me: Heartbeat
  ts: ReturnType<typeof newTickState>
  running: boolean
  lastFull: number
  hasFlash: boolean
  /** Some session is busy: redraw each tick so its mark turns. */
  anyBusy: boolean
  last: Snapshot | null
  /** The session directory (session.start's cwd): the chip's toggle script is looked up there. */
  cwd: string
  /** The session's project (main checkout; '' outside a repo), its tab's color (CLAUDE_TAB_COLOR), and when its dot color was last read. */
  repo: string
  tabColor: string
  colorAt: number
  /** Set by `/hud band|pane` (true) or `/hud off` (false) in this process only: it overrides showForNames here and nowhere else. */
  forceShow: boolean | null
} = {
  me: { id: '', name: '', model: '', account: 1, tokens: 0, window: 1_000_000, state: 'idle', activity: '', at: 0 },
  ts: newTickState(),
  running: false,
  lastFull: 0,
  hasFlash: false,
  anyBusy: false,
  last: null,
  cwd: '',
  repo: '',
  tabColor: '',
  colorAt: 0,
  forceShow: null,
}

/**
 * Drawing is limited to the named sessions (default the orchestrator seat), but every session keeps its timer and heartbeat:
 * the shown HUD lists all sessions only because the hidden ones still write their files.
 */
function shown(): boolean {
  return S.forceShow ?? shownByConfig()
}

function shownByConfig(): boolean {
  const names = S.cfg?.showForNames ?? []
  return names.length === 0 || names.includes(S.me.name)
}

function makeIo($: Dollar): Io {
  return {
    read: p => $.fs.read(p).then(String, () => null),
    writeAtomic: async (p, text) => {
      const tmp = `${p}.${S.me.id}.tmp`
      await $.fs.write(tmp, text)
      // One spawn: owner-only permissions, then the atomic rename.
      await $.process.run(['sh', '-c', 'chmod 600 "$1" && mv -f "$1" "$2"', 'sh', tmp, p])
    },
    list: p => $.fs.list(p).then(es => es.filter(x => x.kind === 'file').map(x => ({ name: x.name, mtimeMs: x.mtimeMs })), () => []),
    remove: async p => void (await $.process.run(['rm', '-f', p]).catch(() => undefined)),
    run: (argv, timeoutMs) => $.process.run(argv, timeoutMs ? { timeoutMs } : {}).then(r => ({ exitCode: r.exitCode, stdout: r.stdout, stderr: r.stderr }), () => ({ exitCode: 127, stdout: '' })),
    now: () => $.clock.now(),
  }
}

async function doTick($: Dollar): Promise<void> {
  const { cfg: c, io, exists } = S
  if (S.running || !c || !io || !exists) return
  S.running = true
  try {
    const now = await $.clock.now()
    if (S.lastFull === 0 || now - S.lastFull >= c.refreshMs) {
      S.lastFull = now
      try {
        const u = await $.session.usage()
        S.me.tokens = u.context.tokens ?? S.me.tokens
        S.me.window = u.context.window
      } catch {
        /* no response yet: keep the last reading */
      }
      await refreshColor(c, io, now)
      const snap = await tick(io, c, S.me, S.ts, exists, S.cwd)
      S.hasFlash = Object.keys(S.ts.flash).length > 0
      S.anyBusy = snap.sessions.some(x => x.state === 'busy')
      S.last = snap
      await update($, snapA, () => snap)
      await update($, flashA, () => ({ ...S.ts.flash }))
    } else if (S.hasFlash || S.anyBusy) {
      // Between full refreshes only the clock moves, so a flash blinks and a busy mark turns without any disk or process work.
      await update($, snapA, s => (s ? { ...s, now } : s))
    }
  } catch (err) {
    $.ui.status(`status-hud: ${String(err).slice(0, 80)}`)
  } finally {
    S.running = false
  }
}

/** The dot color: re-read every minute, since the launcher records a project's color when it opens its first tab. */
async function refreshColor(c: Config, io: Io, now: number): Promise<void> {
  if (S.colorAt !== 0 && now - S.colorAt < 60_000) return
  S.colorAt = now
  // Either file may be absent (no launcher record, no overlay): read as '' and the next source applies.
  const colors = S.repo ? ((await io.read(`${c.kitRuntimeDir}/tab-colors`)) ?? '') : ''
  const overlay = S.repo ? ((await io.read(`${S.repo}/docs/orchestration/ORCHESTRATION.md`)) ?? '') : ''
  S.me.color = projectColor(S.repo, colors, overlay, S.tabColor)
}

async function flipQuiet($: Dollar): Promise<string> {
  const { cfg: c, io } = S
  if (!c || !io) return 'Status HUD is starting.'
  const r = await toggleQuietMode(io, c, S.last?.quietMode ?? null)
  // A failure is state, not just a toast: the chip stays red until it expires or a press works.
  S.ts.quietErr = r.ok ? null : quietFailure(r, await $.clock.now())
  S.lastFull = 0
  await doTick($)
  const msg = r.ok ? quietNote(r.wanted) : `Quiet ${r.wanted ? 'on' : 'off'} failed (${S.ts.quietErr?.msg}). Run it by hand to see why: ${r.wanted ? c.quietOnCmd : c.quietOffCmd}`
  $.ui.toast(msg)
  return msg
}

async function setVariant($: Dollar, v: 'band' | 'pane' | 'off'): Promise<string> {
  S.forceShow = v !== 'off'
  await update($, variantA, () => v)
  // The saved look is shared by every session: a hidden session peeking with /hud (and its /hud off to undo the peek)
  // must not leave the seat starting with no HUD or the other look.
  if (shownByConfig()) await $.store.set('variant', v)
  if (v === 'pane') {
    const r = await $.ui.open({ id: PANE, title: 'Status HUD' })
    return r.isPlaced ? 'Status HUD: pane.' : 'Status HUD: the pane could not be seated (widen the terminal).'
  }
  await $.ui.close({ id: PANE })
  return `Status HUD: ${v}.`
}

async function viewOf($: Dollar): Promise<View | null> {
  const snap = await read($, snapA)
  if (!snap || !S.cfg) return null
  return { snap, cfg: S.cfg, flash: await read($, flashA), sel: await read($, selA), now: snap.now }
}

function press($: Dollar, id: string): void {
  if (id === 'quiet') void flipQuiet($)
  else if (id.startsWith('sel:')) void update($, selA, () => Number(id.slice(4)))
}

function paint($: Dollar, t: Table, lines: readonly Line[]) {
  const { Box, Text, Button } = t
  return (
    <Box flexDirection="column">
      {lines.map((l, i) => (
        <Box key={`l${i}`}>
          {l.map((sg, j) => {
            const texts = sg.runs.map((r, k) => (
              <Text key={`r${k}`} color={r.fg} {...(r.bg ? { backgroundColor: r.bg } : {})} bold={r.bold}>
                {r.text}
              </Text>
            ))
            return sg.press ? (
              <Button key={`p-${sg.press}`} plain onPress={() => press($, sg.press as string)}>
                {texts}
              </Button>
            ) : (
              <Text key={`s${i}-${j}`} wrap="truncate">
                {texts}
              </Text>
            )
          })}
        </Box>
      ))}
    </Box>
  )
}

export const register: Register = (on, options) => {
  on('session.start', async ($, e, next) => {
    const home = (await $.env.get('HOME')) ?? ''
    const c = parseConfig(options, home)
    S.cfg = c
    S.io = makeIo($)
    S.exists = p => $.fs.exists(p)
    S.cwd = e.cwd ?? ''
    const saved = await $.store.get('variant')
    if (saved === 'band' || saved === 'pane' || saved === 'off') await update($, variantA, () => saved)
    // Owner-only status dir, but only a directory we create ourselves (a configured shared dir keeps its mode).
    await ensureStatusDirs(S.io, c.statusDir)
    const me = S.me
    me.id = await $.session.id()
    me.model = (await $.session.model()).replace(/^claude-/, '').replace(/-\d.*$/, '')
    // The engine gives a mod no session name: read it off the parent claude process (`sh`'s parent is claude).
    const ps = await S.io.run(['sh', '-c', 'ps -o args= -p $PPID; echo ::; tr "\\0" "\\n" < /proc/$PPID/environ 2>/dev/null | grep "^CLAUDE_CONFIG_DIR="'])
    const [args = '', env = ''] = ps.stdout.split('::')
    me.name = c.sessionName || (await $.env.get('CLAUDE_HUD_NAME')) || nameFromArgs(args) || `s-${me.id.slice(0, 6)}`
    // The project: the main checkout of the session's directory, so a sibling in its own worktree counts too.
    const common = S.cwd ? await S.io.run(['git', '-C', S.cwd, 'rev-parse', '--path-format=absolute', '--git-common-dir']) : { exitCode: 1, stdout: '' }
    S.repo = common.exitCode === 0 ? repoFromCommonDir(common.stdout) : ''
    if (S.repo) me.project = S.repo.split('/').pop() ?? ''
    S.tabColor = (await $.env.get('CLAUDE_TAB_COLOR')) ?? ''
    S.colorAt = 0
    me.account = accountFromConfigDir(env.trim().replace(/^CLAUDE_CONFIG_DIR=/, '') || (await $.env.get('CLAUDE_CONFIG_DIR')))
    await $.command.register({ name: 'hud', description: 'Status HUD: /hud band | pane | off | quiet | help' })
    $.clock.every(500, () => void doTick($))
    void doTick($)
    if ((saved ?? c.variant) === 'pane' && shown()) void $.ui.open({ id: PANE, title: 'Status HUD' })
    return next(e)
  })

  on('session.end', async ($, e, next) => {
    // No ghost row for the next two minutes: remove our heartbeat at a clean exit.
    if (S.cfg && S.io && S.me.id) await S.io.remove(`${S.cfg.statusDir}/sessions/${S.me.id.replace(/[^A-Za-z0-9_-]/g, '_')}.json`)
    return next(e)
  })

  on('prompt.submit', ($, e, next) => {
    S.me.state = 'busy'
    // Heartbeats are plaintext files: never the prompt text.
    S.me.activity = 'working'
    return next(e)
  }).catch(($, e, next) => next(e))

  on('tool.call', async ($, e, next) => {
    const r = e as unknown as Record<string, unknown>
    // The tool's own description or just its name: a raw command, path or URL can carry a secret and the file is plaintext.
    const detail = typeof r.description === 'string' && r.description !== '' ? r.description : undefined
    S.me.activity = oneLine(detail ? `${e.tool}: ${detail}` : String(e.tool), 100)
    S.me.state = e.tool === 'Bash' ? 'shell' : 'busy'
    const ran = await next(e)
    S.me.state = 'busy'
    return ran
  }).catch(($, e, next) => next(e))

  on('turn.complete', ($, e, next) => {
    S.me.state = 'idle'
    S.me.activity = ''
    S.lastFull = 0
    void doTick($)
    return next(e)
  })

  on('command.run', { command: 'hud' }, async ($, e) => {
    const arg = e.args.trim().toLowerCase()
    if (arg === 'band' || arg === 'pane' || arg === 'off') return { text: await setVariant($, arg) }
    if (arg === 'quiet') return { text: await flipQuiet($) }
    if (arg === 'help') return { text: `${QUIET_EXPLAIN} The chip shows only where the toggle script (quietModeRequiresFile, default scripts/quiet-mode.sh) exists in the session directory, or while quiet mode is already on; set that option to an empty value to always show it.` }
    const snap = await read($, snapA)
    if (!snap) return { text: 'Status HUD: no reading yet.' }
    const over = snap.sessions.filter(x => S.cfg && x.tokens >= S.cfg.reportMark).map(x => x.name)
    return { text: `Status HUD: ${snap.sessions.length} sessions${over.length ? `, over the report mark: ${over.join(', ')}` : ''}. Commands: /hud band | pane | off | quiet | help.` }
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const variant = (await read($, variantA)) ?? S.cfg?.variant ?? 'band'
    const v = await viewOf($)
    if (variant !== 'band' || e.props.hasSurvey || !v || !shown()) return next(e)
    return paint($, $.ui.resolve(e) as unknown as Table, drawBand(v, e.props.bodyColumns, e.props.maxRows))
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e, next) => {
    const v = await viewOf($)
    if (!v || !shown()) return next(e)
    return paint($, $.ui.resolve(e) as unknown as Table, drawPane(v, e.props.bodyColumns))
  })
}
