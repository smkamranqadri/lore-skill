import { expect, openApp, origin, S, test, token } from './helpers.mjs'

const ENDED = 'This session ended. Run lore ui again and open the new link.'

test('the token leaves the address bar, lives in sessionStorage only and goes out as a header on every call', async ({ page }) => {
  const calls = []
  page.on('request', (r) => {
    if (r.url().includes('/api/')) calls.push({ url: r.url(), header: r.headers()['x-lore-token'], method: r.method() })
  })
  await page.goto(S.url)
  await expect(page.getByRole('navigation', { name: 'Screens' })).toBeVisible()
  await expect(page.getByRole('heading', { level: 1, name: 'Memory' })).toBeVisible()
  expect(page.url()).not.toContain(token())
  expect(page.url()).not.toContain('#t=')
  expect(page.url()).not.toContain('t=')
  const store = await page.evaluate(() => ({
    session: Object.fromEntries(Object.entries(sessionStorage)),
    local: localStorage.length,
    cookie: document.cookie,
  }))
  expect(Object.values(store.session)).toEqual([token()])
  expect(store.local).toBe(0)
  expect(store.cookie).toBe('')

  expect(calls.length).toBeGreaterThanOrEqual(3)
  for (const c of calls) expect(c.header, `${c.method} ${c.url}`).toBe(token())
  // a reload keeps the session without the fragment
  await page.reload()
  await expect(page.getByRole('heading', { level: 1, name: 'Memory' })).toBeVisible()
})

test('no token: one screen says the session ended, and the app makes no API call', async ({ page }) => {
  const api = []
  page.on('request', (r) => r.url().includes('/api/') && api.push(r.url()))
  await page.goto(`${origin()}/`)
  await expect(page.getByRole('main').getByText(ENDED, { exact: true })).toBeVisible()
  await expect(page.getByRole('navigation')).toHaveCount(0)
  await expect(page.getByRole('heading')).toHaveCount(0)
  expect(api).toEqual([])
})

test.describe('refused tokens', () => {
  test.use({ allowErrors: true })

  test('a wrong token gets the same single screen', async ({ page }) => {
    await page.goto(`${origin()}/#t=${'x'.repeat(43)}`)
    await expect(page.getByRole('main').getByText(ENDED, { exact: true })).toBeVisible()
    await expect(page.getByRole('navigation')).toHaveCount(0)
    expect(page.url()).not.toContain('#t=')
  })

  test('a 401 in the middle of a session ends it', async ({ page }) => {
    await openApp(page, 'memory')
    await expect(page.getByRole('heading', { level: 1, name: 'Memory' })).toBeVisible()
    await page.route('**/api/graph', (route) => route.fulfill({ status: 401, contentType: 'application/json', body: '{"error":"unauthorized","code":"unauthorized"}' }))
    await page.getByRole('navigation', { name: 'Screens' }).getByRole('link', { name: 'Graph' }).click()
    await expect(page.getByRole('main').getByText(ENDED, { exact: true })).toBeVisible()
    await expect(page.getByRole('navigation')).toHaveCount(0)
  })
})

test('a foreign Host header is refused by the server, with no CORS header and no cookie', async () => {
  const net = await import('node:net')
  const port = new URL(origin()).port
  const raw = await new Promise((resolve) => {
    const s = net.connect(Number(port), '127.0.0.1', () => s.write('GET /api/summary HTTP/1.1\r\nHost: evil.example\r\nX-Lore-Token: ' + token() + '\r\nConnection: close\r\n\r\n'))
    let buf = ''
    s.on('data', (d) => (buf += d))
    s.on('close', () => resolve(buf))
  })
  expect(raw.split('\r\n')[0]).toMatch(/^HTTP\/1\.[01] 403 Forbidden$/) // the stdlib server answers 1.0 or 1.1
  expect(raw).toMatch(/"code":\s*"forbidden"/)
  expect(raw.toLowerCase()).not.toContain('access-control-')
  expect(raw.toLowerCase()).not.toContain('set-cookie')
})
