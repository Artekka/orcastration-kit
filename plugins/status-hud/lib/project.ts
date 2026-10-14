// A session's project and its dot color (dotMode: project). Pure functions; register.tsx reads the files.

const HEX = /^#[0-9a-fA-F]{6}$/

/** The main checkout from `git rev-parse --path-format=absolute --git-common-dir` output; '' outside a repo. */
export function repoFromCommonDir(out: string): string {
  const d = out.trim()
  return d.endsWith('/.git') ? d.slice(0, -5) : ''
}

/** Colors for a project with no recorded one: distinct on a dark background, picked by the project's name. */
export const PALETTE = ['#16a085', '#d35400', '#8e44ad', '#2980b9', '#c0392b', '#27ae60', '#f39c12', '#e84393'] as const

/** The same name always gets the same palette color, on every session and every machine. */
export function paletteColor(name: string): string {
  let h = 2166136261
  for (const ch of name) h = Math.imul(h ^ (ch.codePointAt(0) ?? 0), 16777619) >>> 0
  return PALETTE[h % PALETTE.length] as string
}

/**
 * A session's dot color in project mode, first that applies:
 * 1. its own tab's color (CLAUDE_TAB_COLOR, set by the launcher that opened the tab);
 * 2. the color the launcher recorded for the project (`<kitRuntimeDir>/tab-colors`, lines `<repo path><TAB>#rrggbb`);
 * 3. the team block's `tab_color:` in the project's ORCHESTRATION.md;
 * 4. a palette color from the project's name.
 * Missing files arrive as '' and are skipped; '' only when there is no project and no tab color.
 */
export function projectColor(repo: string, tabColors: string, overlay: string, tabColor = ''): string {
  if (HEX.test(tabColor.trim())) return tabColor.trim()
  if (!repo) return ''
  for (const line of tabColors.split('\n')) {
    const [path, color] = line.split('\t')
    if (path === repo && color && HEX.test(color.trim())) return color.trim()
  }
  const m = /^[ \t]+tab_color:[ \t]*(#[0-9a-fA-F]{6})\b/m.exec(overlay)
  return m?.[1] ?? paletteColor(repo.split('/').pop() ?? repo)
}
