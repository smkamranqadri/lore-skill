import { spawn, spawnSync } from 'node:child_process'
import { mkdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { createInterface } from 'node:readline'
import { test as base, expect } from '@playwright/test'

export { expect }
export const state = () => JSON.parse(readFileSync(process.env.LORE_E2E_STATE, 'utf8'))
export const S = new Proxy({}, { get: (_, k) => state()[k] })
export const origin = () => new URL(state().url).origin
export const token = () => state().url.split('#t=')[1]
export const SHOTS = join(new URL('..', import.meta.url).pathname, 'test-results', 'screens')

// Every test fails on a console error, a page error, a native dialog or a request that leaves the
// origin. A test that makes the server answer 4xx on purpose says so: `allowErrors`, or
// `page.allowConsole(/status of 409/)` for one status.
export const test = base.extend({
  allowErrors: [false, { option: true }],
  page: async ({ page, allowErrors }, use) => {
    const bad = []
    const allowed = []
    page.allowConsole = (re) => allowed.push(re)
    page.on('console', (m) => m.type() === 'error' && bad.push(`console: ${m.text()}`))
    page.on('pageerror', (e) => bad.push(`pageerror: ${e}`))
    page.on('request', (r) => {
      const u = r.url()
      if (!u.startsWith(origin()) && !u.startsWith('data:')) bad.push(`external request: ${u}`)
    })
    page.on('dialog', (d) => {
      bad.push(`native ${d.type()} dialog: ${d.message()}`)
      d.dismiss()
    })
    await use(page)
    const left = bad.filter((m) => !allowed.some((re) => re.test(m)))
    if (!allowErrors) expect(left, 'console, page errors, external requests and native dialogs').toEqual([])
  },
})

/** Open the app with the token, as the printed link does. Resolves once the sidebar is drawn. */
export async function openApp(page, screen, params = {}) {
  await page.goto(state().url)
  await expect(page.getByRole('navigation', { name: 'Screens' })).toBeVisible()
  const q = new URLSearchParams(params).toString()
  await page.evaluate((h) => (location.hash = h), `#/${screen}${q ? `?${q}` : ''}`)
}

/** A full-page screenshot, named for the screen and the theme it was taken in: `<name>-dark.png`. */
export async function shot(page, name) {
  mkdirSync(SHOTS, { recursive: true })
  const theme = await page.evaluate(() => document.documentElement.dataset.theme)
  expect(['dark', 'light']).toContain(theme)
  await page.evaluate(() => window.scrollTo(0, 0)) // sticky panels sit where the page was scrolled to
  await page.screenshot({ path: join(SHOTS, `${name}-${theme}.png`), fullPage: true })
}

export async function apiGet(path) {
  const res = await fetch(origin() + path, { headers: { 'X-Lore-Token': token() } })
  return { status: res.status, body: await res.json() }
}
export async function apiPost(path, body) {
  const res = await fetch(origin() + path, {
    method: 'POST',
    headers: { 'X-Lore-Token': token(), 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  })
  return { status: res.status, body: await res.json() }
}

export const git = (...args) => {
  const res = spawnSync('git', ['-C', state().store, ...args], { encoding: 'utf8', env: { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1' } })
  if (res.status !== 0) throw new Error(`git ${args.join(' ')}: ${res.stderr}`)
  return res.stdout.trim()
}
export const head = () => git('rev-parse', 'HEAD')
export const hubHead = () =>
  spawnSync('git', ['-C', state().hub, 'rev-parse', 'main'], { encoding: 'utf8' }).stdout.trim()

/** Hold the store's run lock (the one every write takes) until release() is called. Mock: a switch. */
export async function holdLock() {
  if (S.mock) {
    await apiPost('/__mock/busy', { on: true })
    return () => apiPost('/__mock/busy', { on: false })
  }
  const py = 'import fcntl, sys\nf = open(sys.argv[1], "w")\nfcntl.flock(f, fcntl.LOCK_EX)\nprint("held", flush=True)\nsys.stdin.read()\n'
  const child = spawn('python3', ['-c', py, join(S.store, '.git', 'lore', 'run.lock')], { stdio: ['pipe', 'pipe', 'inherit'] })
  await new Promise((resolve, reject) => {
    createInterface({ input: child.stdout }).once('line', (l) => (l === 'held' ? resolve() : reject(new Error(l))))
    child.once('exit', () => reject(new Error('the lock holder exited early')))
  })
  // release() may be called twice (once in the test, once in its finally): one exit, one promise
  let released = null
  return () =>
    (released ??= new Promise((resolve) => {
      child.once('exit', resolve)
      child.stdin.end()
    }))
}

/** Make the hub unreachable so the next push fails, and put it back. Mock: a switch. */
export async function breakHub(on) {
  if (S.mock) return apiPost('/__mock/pushfail', { on })
  const moved = S.hub + '.away'
  spawnSync('mv', on ? [S.hub, moved] : [moved, S.hub])
}

export const real = (title, fn) =>
  test(title, async (args, info) => {
    test.skip(S.mock, 'proved against the real server only (it needs the real store)')
    await fn(args, info)
  })

/**
 * WCAG AA over every visible piece of text under `scope`: its colour, composited over the
 * backgrounds behind it, against the 4.5:1 floor (3:1 for large text). Returns the ones below it.
 */
export function contrastFailures(page, scope = 'body') {
  return page.evaluate((sel) => {
    const cv = document.createElement('canvas')
    cv.width = cv.height = 1
    const cx = cv.getContext('2d', { willReadFrequently: true })
    const rgba = (css) => {
      cx.clearRect(0, 0, 1, 1)
      cx.fillStyle = '#000'
      cx.fillStyle = css
      cx.fillRect(0, 0, 1, 1)
      const d = cx.getImageData(0, 0, 1, 1).data
      return [d[0], d[1], d[2], d[3] / 255]
    }
    const over = (top, under) => {
      const a = top[3] + under[3] * (1 - top[3])
      return [0, 1, 2].map((i) => (top[i] * top[3] + under[i] * under[3] * (1 - top[3])) / (a || 1)).concat(a)
    }
    const lum = ([r, g, b]) => {
      const f = (v) => ((v /= 255) <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4)
      return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b)
    }
    const out = []
    const root = document.querySelector(sel)
    for (const el of root.querySelectorAll('*')) {
      const own = [...el.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim())
      if (!own || el.closest('script,style,title') || el.closest(':disabled') || el.getClientRects().length === 0) continue
      const chain = []
      for (let e = el; e; e = e.parentElement) chain.unshift(e)
      let opacity = 1
      let hidden = false
      let bg = [255, 255, 255, 1]
      for (const e of chain) {
        const cs = getComputedStyle(e)
        opacity *= Number(cs.opacity)
        if (cs.visibility === 'hidden') hidden = true
        const c = rgba(cs.backgroundColor)
        if (c[3] > 0) bg = over(c, bg)
      }
      if (hidden || opacity < 0.05) continue
      const cs = getComputedStyle(el)
      const svgText = el instanceof SVGElement
      const fg0 = rgba(svgText ? cs.fill : cs.color)
      fg0[3] *= opacity
      const fg = over(fg0, bg)
      const [hi, lo] = [lum(fg), lum(bg)].sort((a, b) => b - a)
      const ratio = (hi + 0.05) / (lo + 0.05)
      const size = parseFloat(cs.fontSize)
      const large = size >= 24 || (size >= 18.66 && Number(cs.fontWeight) >= 700)
      if (ratio < (large ? 3 : 4.5)) {
        out.push({ text: el.textContent.trim().slice(0, 40), ratio: Math.round(ratio * 100) / 100, fg: fg.slice(0, 3).map(Math.round), bg: bg.slice(0, 3).map(Math.round), tag: el.tagName.toLowerCase() })
      }
    }
    return out
  }, scope)
}
