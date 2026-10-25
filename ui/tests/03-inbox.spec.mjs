import { HAND_A, HAND_B } from './fixture-data.mjs'
import { apiGet, expect, head, openApp, S, shot, test } from './helpers.mjs'

const KIND = { 'hand-edit': 'Hand edit', retire: 'Retire a rule', layout: 'Layout proposal' }

// the shell's own list is the reference for ids, kinds and summaries (real server only)
function shellList() {
  return S.inboxList
    .split('\n')
    .map((l) => /^(\S+)  (\S+)  (.*)$/.exec(l))
    .filter(Boolean)
    .map(([, id, kind, summary]) => ({ id, kind, summary }))
}

test('lists each item with its kind, summary, created date and source, in the order the API gives', async ({ page }) => {
  const api = (await apiGet('/api/inbox')).body.items
  expect(api.map((i) => i.kind).sort()).toEqual(['hand-edit', 'hand-edit', 'layout', 'retire'])
  if (!S.mock) expect(api.map(({ id, kind, summary }) => ({ id, kind, summary }))).toEqual(shellList())

  await openApp(page, 'inbox')
  const items = page.getByRole('list', { name: 'Inbox items' }).locator('li')
  await expect(items).toHaveCount(4)
  for (const [i, it] of api.entries()) {
    const li = items.nth(i)
    await expect(li).toHaveAttribute('data-item', it.id)
    await expect(li.getByText(KIND[it.kind], { exact: true })).toBeVisible()
    await expect(li.getByText(it.id, { exact: true })).toBeVisible()
    await expect(li.getByText(it.summary, { exact: true })).toBeVisible()
    await expect(li.getByText(`created ${it.created.slice(0, 10)} · from ${it.source}`, { exact: true })).toBeVisible()
  }
  // the three summaries the fixture names outright
  await expect(page.getByText(new RegExp(`^${HAND_A.file} \\w{8}: ${HAND_A.text}$`))).toBeVisible()
  await expect(page.getByText(new RegExp(`^${HAND_B.file} \\w{8}: ${HAND_B.text}$`))).toBeVisible()
  await expect(page.getByText(/^top: profile\.md, how-i-work\/, preferences\/, safety\/, stack\/, gotchas\/, tools\/$/)).toBeVisible()
  await expect(page.getByRole('navigation', { name: 'Screens' }).getByLabel('4 waiting')).toHaveText('4')
})

test('each kind has its own icon', async ({ page }) => {
  await openApp(page, 'inbox')
  const icons = await page.locator('[data-item]').evaluateAll((lis) => lis.map((li) => [li.dataset.kind, li.querySelector('svg').innerHTML]))
  const byKind = new Map(icons)
  expect(byKind.size).toBe(3)
  expect(new Set(byKind.values()).size, 'three kinds, three different icons').toBe(3)
  await shot(page, 'inbox')
})

test('Accept and Reject ask in the app dialog first, and Cancel and Escape change nothing', async ({ page }) => {
  const before = S.mock ? null : head()
  await openApp(page, 'inbox')
  const first = page.locator('[data-item]').first()
  await first.getByRole('button', { name: /^Accept / }).click()
  const dialog = page.getByRole('dialog', { name: 'Accept this item?' })
  await expect(dialog).toBeVisible()
  await expect(dialog.getByText((await apiGet('/api/inbox')).body.items[0].summary, { exact: true })).toBeVisible()
  await dialog.getByRole('button', { name: 'Cancel' }).click()
  await expect(dialog).toHaveCount(0)

  await first.getByRole('button', { name: /^Reject / }).click()
  const reject = page.getByRole('dialog', { name: 'Reject this item?' })
  await expect(reject).toBeVisible()
  await page.keyboard.press('Escape')
  await expect(reject).toHaveCount(0)

  expect((await apiGet('/api/inbox')).body.items).toHaveLength(4)
  await expect(page.locator('[data-item]')).toHaveCount(4)
  if (before) expect(head()).toBe(before)
})

// Amendment 1: "pushed" is true, false (a hub is set and the push failed: the only warning) or null (no hub set).
// The answers are stubbed so the store stays as it is; the real routes' three values are G's to test.
test('with no hub ("pushed": null) the push line is plain, never a warning', async ({ page }) => {
  await page.route('**/api/inbox/accept', (route) =>
    route.fulfill({ json: { ok: true, kind: 'hand-edit', commit: 'abcdef0123456789', push: 'hub: none (local git only)', pushed: null } }),
  )
  await page.route('**/api/inbox/reject', (route) => route.fulfill({ json: { ok: true, commit: null, push: null, pushed: null } }))
  await openApp(page, 'inbox')
  const id = (await apiGet('/api/inbox')).body.items[0].id

  await page.locator(`[data-item="${id}"]`).getByRole('button', { name: `Accept ${id}` }).click()
  await page.getByRole('dialog', { name: 'Accept this item?' }).getByRole('button', { name: 'Accept' }).click()
  const ok = page.getByRole('status').filter({ hasText: 'Accepted hand edit' })
  await expect(ok).toContainText('hub: none (local git only)')
  await expect(ok).toContainText('commit abcdef0')
  await expect(page.getByText('Not pushed', { exact: false })).toHaveCount(0)
  await expect(page.getByRole('alert')).toHaveCount(0)

  await ok.getByRole('button', { name: 'Dismiss' }).click()
  await page.locator(`[data-item="${id}"]`).getByRole('button', { name: `Reject ${id}` }).click()
  await page.getByRole('dialog', { name: 'Reject this item?' }).getByRole('button', { name: 'Reject' }).click()
  const rejected = page.getByRole('status').filter({ hasText: 'Rejected hand edit' })
  await expect(rejected).toContainText('no commit')
  await expect(page.getByText('Not pushed', { exact: false })).toHaveCount(0)
  await expect(page.getByRole('alert')).toHaveCount(0)
})

test('a 422 refused shows the server\'s reason in the dialog, which stays open', async ({ page }) => {
  page.allowConsole(/status of 422/)
  const reason = 'the item changed since it was listed; open the inbox again'
  await page.route('**/api/inbox/accept', (route) => route.fulfill({ status: 422, json: { error: reason, code: 'refused' } }))
  await openApp(page, 'inbox')
  const id = (await apiGet('/api/inbox')).body.items[0].id
  await page.locator(`[data-item="${id}"]`).getByRole('button', { name: `Accept ${id}` }).click()
  const dialog = page.getByRole('dialog', { name: 'Accept this item?' })
  await dialog.getByRole('button', { name: 'Accept' }).click()
  await expect(dialog.getByRole('alert')).toHaveText(reason)
  await expect(dialog).toBeVisible()
  await dialog.getByRole('button', { name: 'Cancel' }).click()
  await expect(dialog).toHaveCount(0)
  await expect(page.locator('[data-item]')).toHaveCount(4)
})

// The confirm dialog is modal for the keyboard (review F1): Tab and Shift+Tab stay inside it, the page behind is
// inert while it is open (pending too), and focus goes back to the button that opened it.
for (const action of ['Accept', 'Reject']) {
  test(`${action}: the dialog traps Tab and Shift+Tab, the page is inert, and focus returns to the button`, async ({ page }) => {
    page.allowConsole(/status of 409/)
    await openApp(page, 'inbox')
    const first = page.locator('[data-item]').first()
    const id = await first.getAttribute('data-item')
    const opener = first.getByRole('button', { name: `${action} ${id}` })
    const where = () =>
      page.evaluate(() => {
        const a = document.activeElement
        return { inDialog: !!a?.closest('[role=dialog]'), label: a?.textContent?.trim() || a?.getAttribute('role') || a?.tagName, rootInert: document.getElementById('root').inert }
      })

    // open it from the keyboard
    await opener.focus()
    await page.keyboard.press('Enter')
    const dialog = page.getByRole('dialog', { name: `${action} this item?` })
    await expect(dialog).toBeVisible()
    expect(await where()).toEqual({ inDialog: true, label: 'Cancel', rootInert: true })

    // forward: Cancel, the action, then round to Cancel again, for as long as Tab is pressed
    const seen = []
    for (let i = 0; i < 6; i++) {
      await page.keyboard.press('Tab')
      const w = await where()
      expect(w.inDialog, `Tab ${i + 1} stays in the dialog`).toBe(true)
      seen.push(w.label)
    }
    expect(seen).toEqual([action, 'Cancel', action, 'Cancel', action, 'Cancel'])
    // backward from Cancel goes to the action, and round again
    const back = []
    for (let i = 0; i < 4; i++) {
      await page.keyboard.press('Shift+Tab')
      const w = await where()
      expect(w.inDialog, `Shift+Tab ${i + 1} stays in the dialog`).toBe(true)
      back.push(w.label)
    }
    expect(back).toEqual([action, 'Cancel', action, 'Cancel'])
    // the page behind cannot be reached or clicked
    expect(await page.evaluate(() => document.getElementById('root').inert)).toBe(true)
    // even a script cannot focus anything behind it
    expect(await page.evaluate(() => { document.querySelector('nav a')?.focus(); return !!document.activeElement?.closest('[role=dialog]') })).toBe(true)
    await page.mouse.click(30, 200) // where the sidebar is: the scrim takes it, nothing navigates
    await expect(page).toHaveURL(/#\/inbox$/)
    await expect(dialog).toBeVisible()

    // Escape: back on the button that opened it, the page live again
    await page.keyboard.press('Escape')
    await expect(dialog).toHaveCount(0)
    await expect(opener).toBeFocused()
    expect(await page.evaluate(() => document.getElementById('root').inert)).toBe(false)

    // Cancel does the same
    await page.keyboard.press('Enter')
    await expect(dialog).toBeVisible()
    await page.keyboard.press('Enter') // Cancel has focus
    await expect(dialog).toHaveCount(0)
    await expect(opener).toBeFocused()

    // pending: the answer is held, both buttons are disabled, and focus and inertness hold
    await page.route(`**/api/inbox/${action.toLowerCase()}`, async (route) => {
      await new Promise((r) => setTimeout(r, 1500))
      await route.fulfill({ status: 409, json: { error: 'busy', code: 'busy' } })
    })
    await page.keyboard.press('Enter')
    await expect(dialog).toBeVisible()
    await page.keyboard.press('Tab')
    await page.keyboard.press('Enter') // the action
    const pending = dialog.getByRole('button', { name: action })
    await expect(pending).toHaveAttribute('aria-busy', 'true')
    for (const keys of ['Tab', 'Shift+Tab', 'Tab', 'Tab']) {
      await page.keyboard.press(keys)
      const w = await where()
      expect(w.inDialog, `${keys} while pending stays in the dialog`).toBe(true)
      expect(w.rootInert).toBe(true)
    }
    // the answer comes (a busy refusal): the dialog stays, focus is back on a button in it
    await expect(dialog.getByRole('alert')).toBeVisible()
    expect(await where()).toMatchObject({ inDialog: true, rootInert: true })
    await page.keyboard.press('Escape')
    await expect(dialog).toHaveCount(0)
    await expect(opener).toBeFocused()
  })
}
