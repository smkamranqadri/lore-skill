import { contrastFailures, expect, openApp, origin, shot, test } from './helpers.mjs'

// zinc-950 page, zinc-900 cards, zinc-800 borders, zinc-100 text
const DARK = { page: 'rgb(9, 9, 11)', card: 'rgb(24, 24, 27)', border: 'rgb(39, 39, 42)', ink: 'rgb(244, 244, 245)' }
const LIGHT = { page: 'rgb(246, 245, 241)', card: 'rgb(255, 255, 255)', ink: 'rgb(28, 25, 23)' }

// Computed colours come back as rgb(), oklch() or color-mix(), whatever the stylesheet wrote; the
// canvas turns any of them into the rgb() the expectations are written in.
const css = (loc, prop) =>
  loc.evaluate((e, p) => {
    const v = getComputedStyle(e)[p]
    if (!/color|stroke|fill/i.test(p) || p === 'colorScheme') return v
    const cx = document.createElement('canvas').getContext('2d')
    cx.fillStyle = '#000'
    cx.fillStyle = v
    cx.fillRect(0, 0, 1, 1)
    const [r, g, b, a] = cx.getImageData(0, 0, 1, 1).data
    return a === 255 ? `rgb(${r}, ${g}, ${b})` : `rgba(${r}, ${g}, ${b}, ${Math.round((a / 255) * 100) / 100})`
  }, prop)
const theme = (page) => page.evaluate(() => ({ cls: document.documentElement.classList.contains('dark'), attr: document.documentElement.dataset.theme }))
const stored = (page) => page.evaluate(() => Object.fromEntries(Object.entries(localStorage)))
const switchEl = (page) => page.getByRole('switch', { name: 'Light theme' })
const screens = [
  ['memory', { path: 'gotchas/quillfeather.md' }],
  ['graph', {}],
  ['inbox', {}],
  ['changes', {}],
]

test('dark is the default: dark page, cards, borders and text, nothing written to storage', async ({ page }) => {
  await openApp(page, 'memory')
  expect(await theme(page)).toEqual({ cls: true, attr: 'dark' })
  expect(await css(page.locator('body'), 'backgroundColor')).toBe(DARK.page)
  expect(await css(page.locator('body'), 'colorScheme')).toBe('dark')
  const side = page.locator('aside').locator('xpath=..')
  expect(await css(side, 'backgroundColor')).toBe(DARK.card)
  expect(await css(side, 'borderRightColor')).toBe(DARK.border)
  expect(await css(page.getByRole('heading', { level: 1, name: 'Memory' }), 'color')).toBe(DARK.ink)
  expect(await stored(page)).toEqual({})
  await expect(switchEl(page)).toHaveAttribute('aria-checked', 'false')
})

test('the theme switch is a switch, flips the theme, and is remembered across a reload', async ({ page }) => {
  await openApp(page, 'memory')
  const sw = switchEl(page)
  await expect(sw).toBeVisible()
  expect(await sw.evaluate((e) => e.tagName)).toBe('BUTTON')
  await expect(page.locator('aside input[type="checkbox"]')).toHaveCount(0)
  // it lives in the sidebar footer, under the store facts
  const aside = await page.locator('aside').boundingBox()
  const box = await sw.boundingBox()
  expect(box.y).toBeGreaterThan(aside.y + aside.height - 90)
  expect(box.x).toBeLessThan(aside.x + aside.width)

  await sw.click()
  await expect(sw).toHaveAttribute('aria-checked', 'true')
  expect(await theme(page)).toEqual({ cls: false, attr: 'light' })
  expect(await css(page.locator('body'), 'backgroundColor')).toBe(LIGHT.page)
  expect(await css(page.getByRole('heading', { level: 1, name: 'Memory' }), 'color')).toBe(LIGHT.ink)
  expect(await stored(page)).toEqual({ 'lore.theme': 'light' })

  await page.reload()
  await expect(page.getByRole('heading', { level: 1, name: 'Memory' })).toBeVisible()
  expect(await theme(page)).toEqual({ cls: false, attr: 'light' })
  await expect(switchEl(page)).toHaveAttribute('aria-checked', 'true')
  expect(await css(page.locator('body'), 'backgroundColor')).toBe(LIGHT.page)

  await switchEl(page).click()
  await expect(switchEl(page)).toHaveAttribute('aria-checked', 'false')
  expect(await theme(page)).toEqual({ cls: true, attr: 'dark' })
  expect(await stored(page)).toEqual({ 'lore.theme': 'dark' })
  await page.reload()
  await expect(page.getByRole('heading', { level: 1, name: 'Memory' })).toBeVisible()
  expect(await theme(page)).toEqual({ cls: true, attr: 'dark' })
  // the keyboard works too
  await switchEl(page).focus()
  await page.keyboard.press('Space')
  await expect(switchEl(page)).toHaveAttribute('aria-checked', 'true')
})

test('with storage blocked the app still renders, dark, and the switch still works for the visit', async ({ page }) => {
  await page.addInitScript(() => {
    Object.defineProperty(window, 'localStorage', { get() { throw new Error('storage is blocked') } })
  })
  await openApp(page, 'memory')
  expect(await theme(page)).toEqual({ cls: true, attr: 'dark' })
  await switchEl(page).click()
  expect(await theme(page)).toEqual({ cls: false, attr: 'light' })
  await expect(page.getByRole('heading', { level: 1, name: 'Memory' })).toBeVisible()
})

test('light still renders every screen', async ({ page }) => {
  await openApp(page, 'memory')
  await switchEl(page).click()
  for (const [name, params] of screens) {
    await openApp(page, name, params)
    await expect(page.getByRole('heading', { level: 1, name: new RegExp(`^${name}$`, 'i') })).toBeVisible()
    expect(await theme(page)).toEqual({ cls: false, attr: 'light' })
    expect(await css(page.locator('body'), 'backgroundColor')).toBe(LIGHT.page)
    expect(await css(page.locator('aside').locator('xpath=..'), 'backgroundColor')).toBe(LIGHT.card)
    expect(await css(page.getByRole('heading', { level: 1 }), 'color')).toBe(LIGHT.ink)
    if (name === 'memory') await expect(page.getByRole('tree', { name: 'Memory tree' }).getByRole('treeitem').first()).toBeVisible()
    if (name === 'graph') await expect(page.locator('[data-node]').first()).toBeVisible()
    if (name === 'inbox') await expect(page.locator('[data-item]').first()).toBeVisible()
    if (name === 'changes') await expect(page.getByRole('button', { name: 'Load more' })).toBeVisible()
    await shot(page, name)
  }
  // the graph canvas follows the theme too
  await openApp(page, 'graph')
  expect(await css(page.getByRole('group', { name: 'Link graph of memory files' }).locator('xpath=..').locator('xpath=..'), 'backgroundColor')).toBe('rgb(255, 255, 255)')
  const edge = page.locator('line[data-edge]').first()
  expect(await css(edge, 'stroke')).toBe('rgb(161, 161, 170)')
  expect(await css(page.locator('[data-disc]').first(), 'stroke')).toBe('rgb(255, 255, 255)')
})

test('dark: every screen, dialog and notice keeps its text at WCAG AA contrast', async ({ page }) => {
  for (const [name, params] of screens) {
    await openApp(page, name, params)
    await expect(page.getByRole('heading', { level: 1 })).toBeVisible()
    if (name === 'memory') await expect(page.getByRole('article', { name: params.path })).toBeVisible()
    if (name === 'graph') await expect(page.locator('[data-node]').first()).toBeVisible()
    if (name === 'inbox') await expect(page.locator('[data-item]').first()).toBeVisible()
    if (name === 'changes') await expect(page.getByRole('button', { name: 'Load more' })).toBeVisible()
    expect(await contrastFailures(page), `${name} in dark`).toEqual([])
  }

  // a commit with a diff, added and removed lines in their own colours
  await openApp(page, 'changes')
  await page.getByRole('link', { name: /^canon: reword a rule/ }).click()
  const diff = page.getByRole('region', { name: 'Diff' }).locator('pre')
  await expect(diff).toBeVisible()
  const add = diff.locator('div', { hasText: /^\+- / }).first()
  const del = diff.locator('div', { hasText: /^-- / }).first()
  expect(await css(add, 'backgroundColor')).toBe('rgb(2, 44, 34)')
  expect(await css(add, 'color')).toBe('rgb(209, 250, 229)')
  expect(await css(del, 'backgroundColor')).toBe('rgb(76, 5, 25)')
  expect(await css(del, 'color')).toBe('rgb(255, 228, 230)')
  expect(await css(diff, 'backgroundColor')).toBe(DARK.card)
  expect(await contrastFailures(page), 'a diff in dark').toEqual([])
  await shot(page, 'changes')

  // the confirm dialog, its error notice, and the warning notice after a push that failed
  page.allowConsole(/status of 409/)
  await openApp(page, 'inbox')
  await page.route('**/api/inbox/accept', (route) => route.fulfill({ status: 409, json: { error: 'busy', code: 'busy' } }))
  await page.locator('[data-item]').first().getByRole('button', { name: /^Accept / }).click()
  const dialog = page.getByRole('dialog', { name: 'Accept this item?' })
  await expect(dialog).toBeVisible()
  expect(await css(dialog, 'backgroundColor')).toBe(DARK.card)
  expect(await css(page.locator('.fixed.inset-0'), 'backgroundColor')).toBe('rgba(0, 0, 0, 0.6)')
  expect(await contrastFailures(page), 'the dialog in dark').toEqual([])
  await dialog.getByRole('button', { name: 'Accept' }).click()
  await expect(dialog.getByRole('alert')).toHaveText('lore is busy (a session is ending); try again in a moment')
  expect(await css(dialog.getByRole('alert'), 'backgroundColor')).toBe('rgb(76, 5, 25)')
  expect(await contrastFailures(page), 'the busy notice in dark').toEqual([])
  await dialog.getByRole('button', { name: 'Cancel' }).click()

  await page.unroute('**/api/inbox/accept')
  await page.route('**/api/inbox/accept', (route) =>
    route.fulfill({ json: { ok: true, kind: 'hand-edit', commit: 'abcdef0123456789', push: 'hub: push FAILED (unreachable)', pushed: false } }),
  )
  await page.locator('[data-item]').first().getByRole('button', { name: /^Accept / }).click()
  await page.getByRole('dialog').getByRole('button', { name: 'Accept' }).click()
  const warn = page.getByRole('alert').filter({ hasText: 'Not pushed' })
  await expect(warn).toBeVisible()
  expect(await css(warn, 'backgroundColor')).toBe('rgb(69, 26, 3)')
  expect(await contrastFailures(page), 'the warning notice in dark').toEqual([])
})

test('dark: the session-ended screen', async ({ page }) => {
  await page.goto(`${origin()}/`)
  const main = page.getByRole('main')
  await expect(main.getByText('This session ended. Run lore ui again and open the new link.', { exact: true })).toBeVisible()
  expect(await css(page.locator('body'), 'backgroundColor')).toBe(DARK.page)
  expect(await css(main.locator('div').first(), 'backgroundColor')).toBe(DARK.card)
  expect(await contrastFailures(page), 'session ended in dark').toEqual([])
})
