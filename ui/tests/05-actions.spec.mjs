import { HAND_A, HAND_B, HARBOUR, HISTORY, QUILL_CACHE, RETIRE } from './fixture-data.mjs'
import { apiGet, apiPost, breakHub, expect, git, head, holdLock, hubHead, openApp, real, S, shot, test } from './helpers.mjs'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

test.describe.configure({ mode: 'serial' })

const BUSY = 'lore is busy (a session is ending); try again in a moment'
const item = (page, id) => page.locator(`[data-item="${id}"]`)
const pushedLine = () => (S.mock ? 'hub: pushed to /tmp/mock/hub.git' : `hub: pushed to ${S.hub}`)
const files = (rev) => git('show', '--name-only', '--format=', rev).split('\n').filter(Boolean).sort()

async function act(page, id, action) {
  await item(page, id).getByRole('button', { name: `${action} ${id}` }).click()
  const dialog = page.getByRole('dialog', { name: `${action} this item?` })
  await expect(dialog).toBeVisible()
  return dialog
}

test('Accept waits for the dialog, then lands the hand edit as one commit and pushes it', async ({ page }) => {
  const id = S.ids.handA
  const before = S.mock ? null : head()
  await openApp(page, 'inbox')
  const dialog = await act(page, id, 'Accept')
  // nothing has happened yet: the item is still queued and the store has not moved
  expect((await apiGet('/api/inbox')).body.items.map((i) => i.id)).toContain(id)
  if (before) expect(head()).toBe(before)

  await dialog.getByRole('button', { name: 'Accept' }).click()
  await expect(item(page, id)).toHaveCount(0)
  await expect(page.locator('[data-item]')).toHaveCount(3)
  const notice = page.getByRole('status')
  await expect(notice.first()).toContainText(`Accepted hand edit ${id}, commit `)
  await expect(notice.first()).toContainText(pushedLine())
  await expect(page.getByRole('navigation', { name: 'Screens' }).getByLabel('3 waiting')).toBeVisible()

  if (!S.mock) {
    expect(git('rev-list', '--count', `${before}..HEAD`)).toBe('1')
    expect(git('log', '-1', '--format=%s')).toMatch(/^inbox: keep hand edit [0-9a-f]{8} in gotchas\/brindle-api\.md$/)
    expect(files('HEAD')).toEqual(['.lore/meta/gotchas/brindle-api.json'])
    expect(readFileSync(join(S.store, HAND_A.file), 'utf8')).toContain(`- ${HAND_A.text}\n`)
    expect(hubHead()).toBe(head())
    await expect(notice.first()).toContainText(`commit ${head().slice(0, 7)}`)
  }
})

test('Reject takes the hand-written rule out again, as one commit', async ({ page }) => {
  const id = S.ids.handB
  const before = S.mock ? null : head()
  await openApp(page, 'inbox')
  const dialog = await act(page, id, 'Reject')
  if (before) expect(head()).toBe(before)
  await dialog.getByRole('button', { name: 'Reject' }).click()
  await expect(item(page, id)).toHaveCount(0)
  await expect(page.getByRole('status').first()).toContainText(`Rejected hand edit ${id}, commit `)
  if (!S.mock) {
    expect(git('rev-list', '--count', `${before}..HEAD`)).toBe('1')
    expect(git('log', '-1', '--format=%s')).toMatch(/^inbox: reject hand edit [0-9a-f]{8} in preferences\/editor\.md$/)
    expect(readFileSync(join(S.store, HAND_B.file), 'utf8')).not.toContain(HAND_B.text)
    expect(hubHead()).toBe(head())
  }
})

test('a held lock shows the busy message in the dialog, writes nothing, and works once released', async ({ page }) => {
  const id = S.ids.layout
  const before = S.mock ? null : head()
  page.allowConsole(/status of 409/)
  await openApp(page, 'inbox')
  const release = await holdLock()
  try {
    const dialog = await act(page, id, 'Accept')
    await dialog.getByRole('button', { name: 'Accept' }).click()
    await expect(dialog.getByRole('alert')).toHaveText(BUSY)
    await expect(dialog).toBeVisible()
    await expect(item(page, id)).toHaveCount(1)
    if (before) expect(head()).toBe(before)
    await release()
    // the same dialog, once the lock is free
    await dialog.getByRole('button', { name: 'Accept' }).click()
    await expect(item(page, id)).toHaveCount(0)
    await expect(page.getByRole('status').first()).toContainText(`Accepted layout proposal ${id}, commit `)
  } finally {
    await release()
  }
  if (!S.mock) {
    expect(git('log', '-1', '--format=%s')).toMatch(/^inbox: accept layout p-[0-9a-f]{8}: profile\.md, how-i-work\/, /)
    expect(readFileSync(join(S.store, '.lore', 'layout.json'), 'utf8')).toContain('"tools/"')
  }
})

test('a failed push keeps the commit and shows the push line as a warning', async ({ page }) => {
  const id = S.ids.retire
  const before = S.mock ? null : head()
  await openApp(page, 'inbox')
  await breakHub(true)
  try {
    const dialog = await act(page, id, 'Accept')
    await dialog.getByRole('button', { name: 'Accept' }).click()
    await expect(item(page, id)).toHaveCount(0)
    const warn = page.getByRole('alert').filter({ hasText: 'Not pushed:' })
    await expect(warn).toContainText(`Accepted retire a rule ${id}, commit `)
    await expect(warn).toContainText(/Not pushed: .*FAILED/)
    await expect(page.getByRole('status')).toHaveCount(0)
    await shot(page, 'inbox-push-failed')
    if (!S.mock) {
      expect(git('rev-list', '--count', `${before}..HEAD`)).toBe('1')
      expect(git('log', '-1', '--format=%s')).toMatch(/^inbox: retire [0-9a-f]{8} from safety\/backups\.md$/)
      expect(readFileSync(join(S.store, RETIRE.file), 'utf8')).not.toContain(RETIRE.text)
    }
  } finally {
    await breakHub(false)
  }
  // the inbox is empty now
  await expect(page.getByText('The inbox is empty.', { exact: true })).toBeVisible()
  await expect(page.getByText('Nothing is waiting for you.', { exact: true })).toBeVisible()
  expect((await apiGet('/api/inbox')).body.items).toEqual([])
})
