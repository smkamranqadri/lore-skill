import { ago, finalFiles, lastDateOf, readsOf } from './fixture-data.mjs'
import { apiGet, expect, openApp, shot, test } from './helpers.mjs'

const FILES = finalFiles()
const word = (n, one) => `${n} ${one}${n === 1 ? '' : 's'}`

// The tree the owner should see, written out by hand: [kind, path, depth]. Core first, the layout's
// order after it, sub-folders before files inside a folder.
const TREE = [
  ['file', 'core.md', 0],
  ['file', 'profile.md', 0],
  ['dir', 'how-i-work', 0],
  ['file', 'how-i-work/planning.md', 1],
  ['file', 'how-i-work/reviews.md', 1],
  ['dir', 'preferences', 0],
  ['file', 'preferences/editor.md', 1],
  ['dir', 'safety', 0],
  ['file', 'safety/backups.md', 1],
  ['dir', 'stack', 0],
  ['file', 'stack/harbour-tools.md', 1],
  ['dir', 'gotchas', 0],
  ['dir', 'gotchas/legacy', 1],
  ['file', 'gotchas/legacy/ferry-radio.md', 2],
  ['file', 'gotchas/brindle-api.md', 1],
  ['file', 'gotchas/orphaned-tips.md', 1],
  ['file', 'gotchas/quillfeather.md', 1],
]

const tree = (page) => page.getByRole('tree', { name: 'Memory tree' })
const items = (page) => tree(page).getByRole('treeitem')
const folder = (page, path) => tree(page).locator(`[data-folder="${path}"]`)
const file = (page, path) => tree(page).locator(`[data-path="${path}"]`)
const key = (kind, path) => (kind === 'dir' ? `dir:${path}` : path)
const under = (prefix) => FILES.filter((f) => f.path.startsWith(`${prefix}/`))
const focused = (page) => page.evaluate(() => document.activeElement?.getAttribute('data-key'))

test('the tree lists core first, then each folder with its files indented under it', async ({ page }) => {
  await openApp(page, 'memory')
  await expect(items(page)).toHaveCount(TREE.length)
  const keys = await items(page).evaluateAll((els) => els.map((e) => e.getAttribute('data-key')))
  expect(keys).toEqual(TREE.map(([kind, path]) => key(kind, path)))
  const depths = await items(page).evaluateAll((els) => els.map((e) => Number(e.getAttribute('data-depth'))))
  expect(depths).toEqual(TREE.map(([, , depth]) => depth))
  const levels = await items(page).evaluateAll((els) => els.map((e) => Number(e.getAttribute('aria-level'))))
  expect(levels).toEqual(TREE.map(([, , depth]) => depth + 1))
  // every file is in the tree once
  await expect(tree(page).locator('a[data-path]')).toHaveCount(FILES.length)
  // folders start expanded
  await expect(tree(page).locator('[data-folder][aria-expanded="true"]')).toHaveCount(TREE.filter(([k]) => k === 'dir').length)
  await expect(tree(page).locator('[aria-expanded="false"]')).toHaveCount(0)
})

test('each level sits further right than the one above, with a guide line per level', async ({ page }) => {
  await openApp(page, 'memory')
  const left = async (loc) => (await loc.locator('[data-name]').boundingBox()).x
  const x0 = await left(folder(page, 'gotchas'))
  const x1 = await left(folder(page, 'gotchas/legacy'))
  const x2 = await left(file(page, 'gotchas/legacy/ferry-radio.md'))
  // a folder's name and its files' names are one level apart: the folder has a chevron before its icon
  expect(x1 - x0).toBeGreaterThanOrEqual(16)
  expect(x2 - x1).toBeGreaterThanOrEqual(16)
  const xFile1 = await left(file(page, 'gotchas/brindle-api.md'))
  expect(xFile1, 'a file one level down is right of its folder name').toBeGreaterThan(x0)
  // a root file is at the folders' level, not under one
  const root = await left(file(page, 'profile.md'))
  const rootDir = await left(folder(page, 'how-i-work'))
  expect(Math.abs(root - rootDir), 'a root file lines up with a root folder name').toBeLessThanOrEqual(1)

  // one visible guide line per level above the row, as tall as the row
  for (const [kind, path, depth] of TREE) {
    const row = kind === 'dir' ? folder(page, path) : file(page, path)
    const li = row.locator('xpath=..')
    await expect(li.locator('[data-guide]'), `guides on ${path}`).toHaveCount(depth)
    const rowBox = await li.boundingBox()
    for (const g of await li.locator('[data-guide]').all()) {
      const box = await g.boundingBox()
      expect(box.width).toBeGreaterThan(0)
      expect(box.height).toBeCloseTo(rowBox.height, 0)
    }
  }
  // the lines of neighbouring rows meet, so a folder's files hang from one continuous line
  const a = await file(page, 'how-i-work/planning.md').locator('xpath=..').locator('[data-guide]').boundingBox()
  const b = await file(page, 'how-i-work/reviews.md').locator('xpath=..').locator('[data-guide]').boundingBox()
  expect(a.x).toBeCloseTo(b.x, 0)
  expect(Math.abs(a.y + a.height - b.y)).toBeLessThanOrEqual(1)
})

test('a folder row shows its name with file and rule counts, a file row its name, rule count, reads and lint badges', async ({ page }) => {
  await openApp(page, 'memory')
  for (const [kind, path] of TREE.filter(([k]) => k === 'dir')) {
    const files = under(path)
    const rules = files.reduce((n, f) => n + f.rules.length, 0)
    const row = folder(page, path)
    await expect(row.locator('[data-name]')).toHaveText(path.split('/').pop())
    await expect(row.locator('[data-counts]')).toHaveText(`${word(files.length, 'file')} · ${word(rules, 'rule')}`)
  }
  for (const f of FILES) {
    const row = file(page, f.path)
    await expect(row.locator('[data-name]')).toHaveText(f.path.split('/').pop())
    await expect(row.locator('[data-rules]')).toHaveText(word(f.rules.length, 'rule'))
    await expect(row.locator('[data-reads]')).toHaveText(String(readsOf(f)))
    const lint = row.locator('[title^="lint: "]')
    await expect(lint).toHaveCount((f.expectLint ?? []).length)
    for (const gate of f.expectLint ?? []) await expect(row.getByTitle(`lint: ${gate}`)).toHaveText(gate)
  }
  await expect(tree(page).locator('[title^="lint: "]')).toHaveCount(FILES.reduce((n, f) => n + (f.expectLint ?? []).length, 0))
  const total = FILES.reduce((n, f) => n + f.rules.length, 0)
  await expect(page.getByText(`${word(FILES.length, 'file')}, ${word(total, 'rule')}. Read-only.`, { exact: true })).toBeVisible()
})

test('a folder collapses and expands, and nested folders are independent', async ({ page }) => {
  await openApp(page, 'memory')
  const gotchas = folder(page, 'gotchas')
  await gotchas.click()
  await expect(gotchas).toHaveAttribute('aria-expanded', 'false')
  await expect(items(page)).toHaveCount(TREE.length - 5) // legacy, ferry-radio, brindle, orphaned, quillfeather
  await expect(file(page, 'gotchas/quillfeather.md')).toHaveCount(0)
  await expect(folder(page, 'gotchas/legacy')).toHaveCount(0)
  // the others stay open
  await expect(file(page, 'how-i-work/planning.md')).toBeVisible()
  await gotchas.click()
  await expect(gotchas).toHaveAttribute('aria-expanded', 'true')
  await expect(items(page)).toHaveCount(TREE.length)

  const legacy = folder(page, 'gotchas/legacy')
  await legacy.click()
  await expect(legacy).toHaveAttribute('aria-expanded', 'false')
  await expect(file(page, 'gotchas/legacy/ferry-radio.md')).toHaveCount(0)
  await expect(items(page)).toHaveCount(TREE.length - 1)
  await expect(file(page, 'gotchas/brindle-api.md')).toBeVisible()
  await legacy.click()
  await expect(file(page, 'gotchas/legacy/ferry-radio.md')).toBeVisible()

  // the chevron turns with the state
  const chevron = gotchas.locator('svg').first()
  await expect(chevron).toHaveClass(/rotate-90/)
  await gotchas.click()
  await expect(chevron).not.toHaveClass(/rotate-90/)
  // opening a file inside a collapsed folder (a link, the graph) opens its folders
  await page.evaluate(() => (location.hash = '#/memory?path=gotchas%2Flegacy%2Fferry-radio.md'))
  await expect(gotchas).toHaveAttribute('aria-expanded', 'true')
  await expect(file(page, 'gotchas/legacy/ferry-radio.md')).toHaveAttribute('aria-selected', 'true')
})

test('the selected file is highlighted and only that one', async ({ page }) => {
  await openApp(page, 'memory', { path: 'safety/backups.md' })
  await expect(tree(page).locator('[aria-selected="true"]')).toHaveCount(1)
  const sel = file(page, 'safety/backups.md')
  await expect(sel).toHaveAttribute('aria-selected', 'true')
  await expect(sel).toHaveAttribute('aria-current', 'true')
  const bg = (loc) => loc.evaluate((e) => getComputedStyle(e).backgroundColor)
  const idle = await bg(file(page, 'how-i-work/planning.md'))
  expect(await bg(sel), 'the selected row has its own background').not.toBe(idle)
  await expect(page.getByRole('article', { name: 'safety/backups.md' })).toBeVisible()
  await file(page, 'stack/harbour-tools.md').click()
  await expect(file(page, 'stack/harbour-tools.md')).toHaveAttribute('aria-selected', 'true')
  await expect(sel).toHaveAttribute('aria-selected', 'false')
})

test('keyboard: up and down move, left and right close and open, Enter opens', async ({ page }) => {
  await openApp(page, 'memory', { path: 'how-i-work/planning.md' })
  // one tab stop: the selected row
  await expect(tree(page).locator('[tabindex="0"]')).toHaveCount(1)
  await expect(file(page, 'how-i-work/planning.md')).toHaveAttribute('tabindex', '0')
  await file(page, 'how-i-work/planning.md').focus()

  await page.keyboard.press('ArrowDown')
  expect(await focused(page)).toBe('how-i-work/reviews.md')
  await page.keyboard.press('ArrowDown')
  expect(await focused(page)).toBe('dir:preferences')
  await page.keyboard.press('ArrowUp')
  await page.keyboard.press('ArrowUp')
  expect(await focused(page)).toBe('how-i-work/planning.md')
  await expect(tree(page).locator('[tabindex="0"]')).toHaveCount(1)
  await expect(file(page, 'how-i-work/planning.md')).toHaveAttribute('tabindex', '0')

  // left on a file goes to its folder; left on an open folder closes it
  await page.keyboard.press('ArrowLeft')
  expect(await focused(page)).toBe('dir:how-i-work')
  await page.keyboard.press('ArrowLeft')
  await expect(folder(page, 'how-i-work')).toHaveAttribute('aria-expanded', 'false')
  await expect(file(page, 'how-i-work/planning.md')).toHaveCount(0)
  // down skips the hidden files
  await page.keyboard.press('ArrowDown')
  expect(await focused(page)).toBe('dir:preferences')
  await page.keyboard.press('ArrowUp')
  // right opens a closed folder, then steps into it
  await page.keyboard.press('ArrowRight')
  await expect(folder(page, 'how-i-work')).toHaveAttribute('aria-expanded', 'true')
  expect(await focused(page)).toBe('dir:how-i-work')
  await page.keyboard.press('ArrowRight')
  expect(await focused(page)).toBe('how-i-work/planning.md')

  // Enter on a folder toggles, on a file opens it
  await page.keyboard.press('ArrowLeft')
  await page.keyboard.press('Enter')
  await expect(folder(page, 'how-i-work')).toHaveAttribute('aria-expanded', 'false')
  await page.keyboard.press('Enter')
  await expect(folder(page, 'how-i-work')).toHaveAttribute('aria-expanded', 'true')
  await page.keyboard.press('ArrowDown')
  await page.keyboard.press('ArrowDown')
  expect(await focused(page)).toBe('how-i-work/reviews.md')
  await page.keyboard.press('Enter')
  await expect(page).toHaveURL(/#\/memory\?path=how-i-work%2Freviews\.md$/)
  await expect(page.getByRole('article', { name: 'how-i-work/reviews.md' })).toBeVisible()
  await expect(file(page, 'how-i-work/reviews.md')).toHaveAttribute('aria-selected', 'true')

  // the ends
  await page.keyboard.press('End')
  expect(await focused(page)).toBe('gotchas/quillfeather.md')
  await page.keyboard.press('Home')
  expect(await focused(page)).toBe('core.md')
})

test('a file shows its read_when, reads per machine, links and each rule with count, explicit, created and last date', async ({ page }) => {
  const f = FILES.find((x) => x.path === 'how-i-work/planning.md')
  await openApp(page, 'memory', { path: f.path })
  const detail = page.getByRole('article', { name: f.path })
  await expect(detail.getByRole('heading', { level: 2, name: f.title })).toBeVisible()
  await expect(detail.getByText(f.path, { exact: true })).toBeVisible()
  const facts = detail.locator('dl')
  await expect(facts.locator('dd').nth(0)).toHaveText(f.readWhen)
  await expect(facts.locator('dd').nth(1)).toHaveText(
    `fern-desktop: 6 (last ${ago(f.lastReadAgo['fern-desktop'])})pine-laptop: 3 (last ${ago(f.lastReadAgo['pine-laptop'])})`,
  )
  await expect(facts.locator('dd').nth(2).locator('a')).toHaveText(f.links)

  const rules = detail.getByRole('region', { name: 'Rules' })
  await expect(rules.getByRole('heading', { level: 3 })).toHaveText(word(f.rules.length, 'rule'))
  const list = rules.locator('li')
  await expect(list).toHaveCount(f.rules.length)
  for (const [i, rule] of f.rules.entries()) {
    const li = list.nth(i)
    await expect(li.locator('p')).toHaveText(rule.text)
    await expect(li.getByText(`count ×${rule.count}`, { exact: true })).toBeVisible()
    await expect(li.getByText('explicit', { exact: true })).toHaveCount(rule.explicit ? 1 : 0)
    await expect(li.getByText(/^created \d{4}-\d\d-\d\d$/)).toHaveText(`created ${ago(rule.createdAgo)}`)
    await expect(li.getByText(/^last \d{4}-\d\d-\d\d$/)).toHaveText(`last ${lastDateOf(rule)}`)
  }
  await shot(page, 'memory')
})

test('a nested file opens, a file with a hand edit, one that was never read and one with a link to a missing file', async ({ page }) => {
  await openApp(page, 'memory', { path: 'gotchas/legacy/ferry-radio.md' })
  await expect(page.getByRole('article', { name: 'gotchas/legacy/ferry-radio.md' }).getByRole('heading', { level: 2 })).toHaveText('Ferry radio')

  // the fixture's pending hand edit is flagged on its rule
  await openApp(page, 'memory', { path: 'gotchas/brindle-api.md' })
  const li = page.getByRole('region', { name: 'Rules' }).locator('li').filter({ hasText: 'Brindle rate limits reset at midnight UTC' })
  await expect(li.getByText(/^hand edit \d{4}-\d\d-\d\d$/)).toBeVisible()

  await openApp(page, 'memory', { path: 'preferences/editor.md' })
  const facts = page.getByRole('article', { name: 'preferences/editor.md' }).locator('dl')
  await expect(facts.locator('dd').nth(1)).toHaveText('never read')
  await expect(facts.locator('dd').nth(2)).toHaveText('none')

  // a link opens the other file
  await openApp(page, 'memory', { path: 'how-i-work/planning.md' })
  await page.getByRole('article', { name: 'how-i-work/planning.md' }).getByRole('link', { name: 'preferences/editor.md', exact: true }).click()
  await expect(page.getByRole('article', { name: 'preferences/editor.md' })).toBeVisible()
  await expect(file(page, 'preferences/editor.md')).toHaveAttribute('aria-current', 'true')
})

// A path that was asked for and is not in the store opens nothing else (review F2).
test('a broken link in a file is shown as missing and is not a link; a stale route says the file does not exist', async ({ page }) => {
  const missing = 'gotchas/missing-notes.md'
  expect((await apiGet(`/api/file?path=${encodeURIComponent(missing)}`)).status).toBe(404)

  // the fixture's real broken link: quillfeather links to a file that is not there
  await openApp(page, 'memory', { path: 'gotchas/quillfeather.md' })
  const detail = page.getByRole('article', { name: 'gotchas/quillfeather.md' })
  const links = detail.locator('dl dd').nth(2)
  await expect(links.getByRole('link')).toHaveText(['gotchas/brindle-api.md'])
  const broken = links.locator(`[data-missing="${missing}"]`)
  await expect(broken).toHaveText(`${missing}(missing)`)
  await expect(broken).toHaveAttribute('title', 'this file does not exist')
  await expect(detail.getByRole('link', { name: missing })).toHaveCount(0)
  await broken.click({ force: true }) // nothing to follow
  await expect(page).toHaveURL(/#\/memory\?path=gotchas%2Fquillfeather\.md$/)
  await expect(detail).toBeVisible()

  // a stale bookmark: the route names a file that is not in the list
  await openApp(page, 'memory', { path: missing })
  const article = page.getByRole('article')
  await expect(article).toHaveCount(1)
  await expect(article).toHaveAttribute('aria-label', missing)
  await expect(article.getByRole('heading', { level: 2 })).toHaveText('This file does not exist')
  await expect(article.getByText(missing, { exact: true })).toBeVisible()
  await expect(page.getByRole('article', { name: 'core.md' })).toHaveCount(0)
  await expect(page.getByRole('tree', { name: 'Memory tree' }).locator('[aria-selected="true"]')).toHaveCount(0)
  await expect(page).toHaveURL(new RegExp(`#/memory\\?path=${encodeURIComponent(missing).replace(/\./g, '\\.')}$`))
  // the list is still there and works
  await file(page, 'safety/backups.md').click()
  await expect(page.getByRole('article', { name: 'safety/backups.md' })).toBeVisible()

  // other stale shapes
  for (const path of ['nope.md', '../core.md', 'gotchas/', 'core.md/x']) {
    await openApp(page, 'memory', { path })
    await expect(page.getByRole('article')).toHaveAttribute('aria-label', path)
    await expect(page.getByRole('heading', { level: 2 })).toHaveText('This file does not exist')
  }

  // only no path at all opens the first file
  await openApp(page, 'memory')
  await expect(page.getByRole('article', { name: 'core.md' })).toBeVisible()
  await openApp(page, 'memory', { path: '' })
  await expect(page.getByRole('article', { name: 'core.md' })).toBeVisible()
})
