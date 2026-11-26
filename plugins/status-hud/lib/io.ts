/** The few engine calls the HUD makes, behind an interface so tests can run the logic with fakes. */
export type RunResult = { exitCode: number; stdout: string; stderr?: string }
export type Io = {
  read(path: string): Promise<string | null>
  /** Write via tmp + mv so a reader never sees half a file. */
  writeAtomic(path: string, text: string): Promise<void>
  list(dir: string): Promise<{ name: string; mtimeMs: number }[]>
  remove(path: string): Promise<void>
  /** Runs from the home directory unless `cwd` names another (the quiet chip's commands run in the session's directory). */
  run(argv: string[], timeoutMs?: number, cwd?: string): Promise<RunResult>
  now(): Promise<number>
}

export const sh = (cmd: string): string[] => ['sh', '-c', cmd]
