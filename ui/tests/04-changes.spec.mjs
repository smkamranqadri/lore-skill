import { HAND_SUBJECTS, HISTORY, INIT_SUBJECT, R1, R1_REWORDED, SEED_SUBJECT } from './fixture-data.mjs'
import { apiGet, apiPost, expect, git, openApp, S, shot, test } from './helpers.mjs'

// oldest first, as the fixture builder commits them
const PLAN = [
  { subject: INIT_SUBJECT, kind: 'Owner' },
  { subject: SEED_SUBJECT, kind: 'Owner' },
  ...HISTORY.map((h) => ({ subject: h.subject, kind: h.kind === 'canon' ? 'Canon' : 'Loremaster' })),
  ...HAND_SUBJECTS.map((subject) => ({ subject, kind: 'Owner' })),
]
const NEWEST_FIRST = [...PLAN].reverse()
const PAGE = 20
const plural = (n) => `${n} file${n === 1 ? '' : 's'}`

const rows = (page) => page.getByRole('navigation', { name: 'Commits' }).locator('a[data-sha]')

test('lists commits newest first with a kind badge, short sha, date and file count', async ({ page }) => {
  const api = (await apiGet('/api/changes?limit=200')).body
  expect(api.commits.map((c) => c.subject)).toEqual(NEWEST_FIRST.map((c) => c.subject))
  if (!S.mock) expect(git('log', '--format=%s')).toBe(NEWEST_FIRST.map((c) => c.subject).join('\n'))

  await openApp(page, 'changes')
  await expect(rows(page)).toHaveCount(PAGE)
  for (const [i, want] of NEWEST_FIRST.slice(0, PAGE).entries()) {
    const row = rows(page).nth(i)
    const c = api.commits[i]
    await expect(row.getByText(want.subject, { exact: true })).toBeVisible()
    await expect(row.getByText(want.kind, { exact: true })).toBeVisible()
    await expect(row.getByText(c.short, { exact: true })).toBeVisible()
    await expect(row.getByText(`${c.date.slice(0, 10)} ${c.date.slice(11, 16)}`, { exact: true })).toBeVisible()
    await expect(row.getByText(plural(c.files.length), { exact: true })).toBeVisible()
    if (!S.mock) expect(c.files.length).toBe(git('show', '--name-only', '--format=', c.sha).split('\n').filter(Boolean).length)
  }
  // the newest commit is open by default
  await expect(rows(page).first()).toHaveAttribute('aria-current', 'true')
  await expect(page.getByRole('article').getByRole('heading', { level: 2 })).toHaveText(NEWEST_FIRST[0].subject)
})

test('kinds have their own icons', async ({ page }) => {
  await openApp(page, 'changes')
  const icons = await rows(page).evaluateAll((as) => as.map((a) => [a.textContent.includes('Owner') ? 'owner' : a.textContent.includes('Canon') ? 'canon' : 'loremaster', a.querySelector('svg').innerHTML]))
  const byKind = new Map(icons)
  expect(byKind.size).toBe(3)
  expect(new Set(byKind.values()).size).toBe(3)
})

test('Load more shows a spinner at the button width, never "Saving...", then adds the rest', async ({ page }) => {
  await openApp(page, 'changes')
  const more = page.getByRole('button', { name: 'Load more' })
  await expect(more).toBeVisible()
  await page.route(/\/api\/changes\?.*before=/, async (route) => {
    await new Promise((r) => setTimeout(r, 1200))
    await route.continue()
  })
  const before = await more.boundingBox()
  await more.click()
  const busy = page.getByRole('button', { name: 'Load more' })
  await expect(busy).toHaveAttribute('aria-busy', 'true')
  await expect(busy).toBeDisabled()
  const during = await busy.boundingBox()
  expect(during.width).toBe(before.width)
  expect(during.height).toBe(before.height)
  await expect(busy.getByRole('status')).toBeVisible()
  expect(await busy.locator('span').first().evaluate((el) => getComputedStyle(el).opacity)).toBe('0')
  await expect(page.getByText(/saving/i)).toHaveCount(0)

  await expect(rows(page)).toHaveCount(PLAN.length)
  await expect(page.getByRole('button', { name: 'Load more' })).toHaveCount(0)
  await expect(rows(page).last().getByText(INIT_SUBJECT, { exact: true })).toBeVisible()
})

test('a commit shows its kind, files and the rule text diff', async ({ page }) => {
  const reword = (await apiGet('/api/changes?limit=200')).body.commits.find((c) => c.subject === 'canon: reword a rule in how-i-work/reviews.md')
  await openApp(page, 'changes')
  await rows(page).filter({ hasText: reword.subject }).click()
  const art = page.getByRole('article', { name: `Commit ${reword.short}` })
  await expect(art.getByRole('heading', { level: 2 })).toHaveText(reword.subject)
  await expect(art.getByText('Canon', { exact: true })).toBeVisible()
  await expect(art.getByText(reword.short, { exact: true })).toBeVisible()
  const files = art.getByRole('region', { name: 'Files' }).locator('li')
  await expect(files.filter({ hasText: /^modifiedhow-i-work\/reviews\.md$/ })).toHaveCount(1)
  await expect(art.getByText(/^Metadata also changed: .*\.lore\/meta\/how-i-work\/reviews\.json/)).toBeVisible()
  const diff = art.getByLabel('Diff').first()
  await expect(diff.getByText(`-- ${R1}`, { exact: true })).toHaveCount(1)
  await expect(diff.getByText(`+- ${R1_REWORDED}`, { exact: true })).toHaveCount(1)
  await shot(page, 'changes')
})

test('Changes is read-only: no Revert, no dialog, no note, and the server has no revert route or field', async ({ page }) => {
  const all = (await apiGet('/api/changes?limit=200')).body.commits
  for (const subject of [INIT_SUBJECT, HISTORY[2].subject, 'canon: reword a rule in how-i-work/reviews.md']) {
    const c = all.find((x) => x.subject === subject)
    expect(Object.keys((await apiGet(`/api/commit?sha=${c.sha}`)).body)).not.toContain('revert')
    await openApp(page, 'changes', { sha: c.sha })
    const art = page.getByRole('article', { name: `Commit ${c.short}` })
    await expect(art.getByRole('heading', { level: 2 })).toHaveText(subject)
    await expect(page.getByRole('button', { name: /revert/i })).toHaveCount(0)
    await expect(art.getByRole('button')).toHaveCount(0)
    await expect(art.getByRole('note')).toHaveCount(0)
    await expect(page.getByRole('dialog')).toHaveCount(0)
    // nothing on the screen speaks of reverting, or of it coming later
    await expect(page.getByRole('main')).not.toContainText(/revert|undo|coming|soon|later|P4b/i)
  }
  const gone = await apiPost('/api/revert', { sha: all[0].sha })
  expect(gone.status).toBe(404)
  expect(gone.body.error).toBe('no such route')
})
