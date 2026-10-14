import { expect, test } from 'claude-code/testing'

import { PALETTE, paletteColor, projectColor, repoFromCommonDir } from '../lib/project'

test('the project is the main checkout, also from inside a worktree', async () => {
  expect(repoFromCommonDir('/home/u/projects/Book Shop/.git\n')).toBe('/home/u/projects/Book Shop')
  expect(repoFromCommonDir('/home/u/projects/x/.git/worktrees/w1\n')).toBe('')
  expect(repoFromCommonDir('')).toBe('')
})

test('dot color: the tab\'s own color, else the recorded one, else the team block, else a palette color', async () => {
  const rec = '/p/a\t#16a085\n/p/b\t#d35400\n'
  // The session's own tab color (CLAUDE_TAB_COLOR) wins, so the dot matches the tab it sits in.
  expect(projectColor('/p/b', rec, '', '#8e44ad')).toBe('#8e44ad')
  expect(projectColor('', '', '', '#8e44ad ')).toBe('#8e44ad')
  expect(projectColor('/p/b', rec, '', 'purple')).toBe('#d35400')
  expect(projectColor('/p/c', rec, 'team:\n  tab_color:        #27ae60\n')).toBe('#27ae60')
  // No launcher record at all (the tab-colors file is absent, read as ''): the project's own color.
  expect(projectColor('/p/c', '', '')).toBe(paletteColor('c'))
  expect(projectColor('/p/c', 'garbage\n\t\n', 'team:\n  tab_color:        none\n')).toBe(paletteColor('c'))
  // No project and no tab color: no color (the row's dot is grey).
  expect(projectColor('', rec, '')).toBe('')
})

test('a project\'s palette color is stable and comes from the palette', async () => {
  expect(paletteColor('book-shop')).toBe(paletteColor('book-shop'))
  expect(PALETTE as readonly string[]).toContain(paletteColor('lunch-diary'))
  const many = new Set(['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j'].map(paletteColor))
  expect(many.size).toBeGreaterThan(3)
})
