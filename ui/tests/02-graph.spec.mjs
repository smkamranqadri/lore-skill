import { finalFiles, readsOf } from './fixture-data.mjs'
import { expect, openApp, shot, test } from './helpers.mjs'

const FILES = finalFiles()
const MAX_HEAT = Math.max(...FILES.map(readsOf)) // 17

// Colour by top-level folder, one fixed palette, in the order the folders first appear.
const FOLDER_COLOUR = {
  'core.md': '#64c8ff',
  'profile.md': '#a78bfa',
  'how-i-work/': '#34d399',
  'preferences/': '#fbbf24',
  'safety/': '#f87171',
  'stack/': '#f472b6',
  'gotchas/': '#2dd4bf',
}
const folderOf = (path) => (path === 'core.md' ? 'core.md' : ['profile.md', 'how-i-work/', 'preferences/', 'safety/', 'stack/', 'gotchas/'].find((t) => (t.endsWith('/') ? path.startsWith(t) : path === t)))

// Links in and out, counting only links whose target exists.
const EDGES = FILES.flatMap((f) => f.links.filter((l) => FILES.some((x) => x.path === l)).map((l) => [f.path, l]))
const degree = (path) => EDGES.filter(([a, b]) => a === path || b === path).length

const canvas = (page) => page.getByRole('group', { name: 'Link graph of memory files' })
const node = (page, path) => canvas(page).locator(`[data-node="${path}"]`)
const zoomOf = async (page) => Number(await canvas(page).locator('g[data-zoom]').getAttribute('data-zoom'))
// the zoom once the first fit has landed (it is set a frame after the graph is drawn)
const settledZoom = async (page) => {
  let last = await zoomOf(page)
  for (let i = 0; i < 20; i++) {
    await page.waitForTimeout(60)
    const now = await zoomOf(page)
    if (now === last && i >= 2) return now
    last = now
  }
  return last
}
const centre = async (loc) => {
  const b = await loc.boundingBox()
  return { x: b.x + b.width / 2, y: b.y + b.height / 2 }
}
const disc = (page, path) => node(page, path).locator('[data-disc]')
const cssOf = (loc, prop) => loc.evaluate((e, p) => getComputedStyle(e).getPropertyValue(p), prop)

test('draws one node per file, a link per edge, coloured by top-level folder', async ({ page }) => {
  await openApp(page, 'graph')
  await expect(canvas(page).locator('[data-node]')).toHaveCount(FILES.length)
  await expect(canvas(page).locator('line[data-edge]')).toHaveCount(5)
  expect(EDGES).toHaveLength(5)
  for (const f of FILES) {
    const d = disc(page, f.path)
    await expect(d, f.path).toHaveAttribute('fill', FOLDER_COLOUR[folderOf(f.path)])
    await expect(node(page, f.path)).toHaveAttribute('data-folder', folderOf(f.path))
    // a thin dark outline
    expect(await cssOf(d, 'stroke')).toBe('rgb(24, 24, 27)')
    await expect(d).toHaveAttribute('stroke-width', '1.5')
  }
  // files in one folder share a colour, different folders differ
  const colours = await Promise.all(FILES.map((f) => disc(page, f.path).getAttribute('fill')))
  expect(new Set(colours).size).toBe(Object.keys(FOLDER_COLOUR).length)
})

test('node radius is 5 + sqrt(degree) * 3.5', async ({ page }) => {
  await openApp(page, 'graph')
  for (const f of FILES) {
    const r = Number(await disc(page, f.path).getAttribute('r'))
    expect(r, f.path).toBeCloseTo(5 + Math.sqrt(degree(f.path)) * 3.5, 6)
  }
  // a file with no links is the smallest, one with two the largest
  expect(degree('core.md')).toBe(0)
  expect(degree('how-i-work/planning.md')).toBe(2)
  expect(Number(await disc(page, 'core.md').getAttribute('r'))).toBe(5)
  expect(Number(await disc(page, 'how-i-work/planning.md').getAttribute('r'))).toBeGreaterThan(Number(await disc(page, 'preferences/editor.md').getAttribute('r')))
})

test('core has a double ring and orphans a red ring, nothing else has either', async ({ page }) => {
  await openApp(page, 'graph')
  await expect(canvas(page).locator('[data-ring="core"]')).toHaveCount(2)
  await expect(canvas(page).locator('[data-ring="orphan"]')).toHaveCount(1)
  const coreR = Number(await disc(page, 'core.md').getAttribute('r'))
  const rings = node(page, 'core.md').locator('[data-ring="core"]')
  expect(Number(await rings.nth(0).getAttribute('r'))).toBeCloseTo(coreR + 3, 6)
  expect(Number(await rings.nth(1).getAttribute('r'))).toBeGreaterThan(coreR + 3)
  await expect(node(page, 'core.md').locator('[data-ring="orphan"]')).toHaveCount(0)

  const orphan = node(page, 'gotchas/orphaned-tips.md')
  await expect(orphan).toHaveAttribute('data-orphan', 'true')
  const ring = orphan.locator('[data-ring="orphan"]')
  await expect(ring).toHaveAttribute('stroke', '#ef4444')
  await expect(ring).toHaveAttribute('fill', 'none')
  expect(Number(await ring.getAttribute('r'))).toBeCloseTo(Number(await disc(page, 'gotchas/orphaned-tips.md').getAttribute('r')) + 3, 6)
  for (const f of FILES.filter((x) => !x.expectLint?.includes('orphan'))) {
    await expect(node(page, f.path)).toHaveAttribute('data-orphan', 'false')
    await expect(node(page, f.path).locator('[data-ring="orphan"]')).toHaveCount(0)
  }
})

test('a halo glows brighter the more a file is read, and a file never read has none', async ({ page }) => {
  await openApp(page, 'graph')
  const never = FILES.filter((f) => readsOf(f) === 0).map((f) => f.path)
  expect(never.length).toBeGreaterThan(0)
  for (const p of never) await expect(node(page, p).locator('[data-halo]'), p).toHaveCount(0)
  const read = FILES.filter((f) => readsOf(f) > 0)
  for (const f of read) {
    const halo = node(page, f.path).locator('[data-halo]')
    await expect(halo, f.path).toHaveCount(1)
    expect(Number(await halo.getAttribute('opacity')), f.path).toBeCloseTo(0.12 + 0.55 * (readsOf(f) / MAX_HEAT), 6)
    // the halo takes the folder colour, it does not replace it
    await expect(halo).toHaveAttribute('fill', FOLDER_COLOUR[folderOf(f.path)])
  }
  const byReads = [...read].sort((a, b) => readsOf(a) - readsOf(b))
  const ops = []
  for (const f of byReads) ops.push(Number(await node(page, f.path).locator('[data-halo]').getAttribute('opacity')))
  expect(ops).toEqual([...ops].sort((a, b) => a - b))
  expect(ops[0]).toBeLessThan(ops[ops.length - 1])
})

test('edges are thin straight grey lines between node centres', async ({ page }) => {
  await openApp(page, 'graph')
  const edges = canvas(page).locator('line[data-edge]')
  // the zoom and the widths are read in one go, so a fit that lands in between cannot split them
  const [k, widths] = await canvas(page).evaluate((svg) => [
    Number(svg.querySelector('g[data-zoom]').getAttribute('data-zoom')),
    [...svg.querySelectorAll('line[data-edge]')].map((l) => Number(l.getAttribute('stroke-width'))),
  ])
  expect(widths).toHaveLength(5)
  for (const w of widths) expect(w).toBeCloseTo(1.2 / k, 3)
  for (const e of await edges.all()) {
    await expect(e).toHaveAttribute('opacity', '0.7')
    expect(await cssOf(e, 'stroke')).toBe('rgb(63, 63, 70)')
  }
  // an edge runs from one node's centre to the other's
  const at = async (path) => {
    const t = await node(page, path).getAttribute('transform')
    const [x, y] = /translate\(([-\d.e]+) ([-\d.e]+)\)/.exec(t).slice(1).map(Number)
    return { x, y }
  }
  const ends = []
  for (const e of await edges.all()) ends.push([Number(await e.getAttribute('x1')), Number(await e.getAttribute('y1')), Number(await e.getAttribute('x2')), Number(await e.getAttribute('y2'))])
  for (const [a, b] of EDGES) {
    const pa = await at(a)
    const pb = await at(b)
    const hit = ends.some(([x1, y1, x2, y2]) => Math.hypot(x1 - pa.x, y1 - pa.y) < 0.01 && Math.hypot(x2 - pb.x, y2 - pb.y) < 0.01)
    expect(hit, `${a} -> ${b}`).toBe(true)
  }
})

test('the layout is the same on every load', async ({ page }) => {
  const read = async () => {
    await openApp(page, 'graph')
    await expect(canvas(page).locator('[data-node]')).toHaveCount(FILES.length)
    return canvas(page).locator('[data-node]').evaluateAll((els) => els.map((e) => `${e.getAttribute('data-node')}@${e.getAttribute('transform')}`))
  }
  const first = await read()
  await page.reload()
  const second = await read()
  expect(second).toEqual(first)
})

test('hovering a node lights it and its neighbours, dims the rest, and leaving puts it back', async ({ page }) => {
  await openApp(page, 'graph')
  const bright = ['how-i-work/planning.md', 'how-i-work/reviews.md', 'preferences/editor.md']
  const opacity = (path) => node(page, path).getAttribute('opacity')
  for (const f of FILES) expect(await opacity(f.path)).toBe('1')
  await expect(canvas(page).locator('[data-glow]')).toHaveCount(0)

  await disc(page, 'how-i-work/planning.md').hover()
  for (const f of FILES) {
    const lit = bright.includes(f.path)
    await expect(node(page, f.path), f.path).toHaveAttribute('opacity', lit ? '1' : '0.15')
    await expect(node(page, f.path)).toHaveAttribute('data-dim', lit ? 'false' : 'true')
  }
  // a glow behind the hovered node only
  await expect(canvas(page).locator('[data-glow]')).toHaveCount(1)
  await expect(node(page, 'how-i-work/planning.md').locator('[data-glow]')).toHaveCount(1)
  // its two edges stay bright, the other three dim to 0.1
  await expect(canvas(page).locator('line[data-edge][opacity="1"]')).toHaveCount(2)
  await expect(canvas(page).locator('line[data-edge][opacity="0.1"]')).toHaveCount(3)
  await expect(canvas(page).locator('line[data-lit="true"]')).toHaveCount(2)
  await shot(page, 'graph-hover')

  await page.mouse.move(5, 5)
  for (const f of FILES) await expect(node(page, f.path)).toHaveAttribute('opacity', '1')
  await expect(canvas(page).locator('[data-glow]')).toHaveCount(0)
  await expect(canvas(page).locator('line[data-edge][opacity="0.7"]')).toHaveCount(5)
})

test('labels: every file is named, light grey, 12 px whatever the zoom', async ({ page }) => {
  await openApp(page, 'graph')
  const labels = canvas(page).locator('[data-label]')
  await expect(labels).toHaveCount(FILES.length)
  const names = FILES.map((f) => f.path.replace(/^.*\//, '').replace(/\.md$/, ''))
  await expect(labels).toHaveText(names)
  expect(await cssOf(labels.first(), 'fill')).toBe('rgb(212, 212, 216)')
  for (const zoomBy of [0, 3]) {
    for (let i = 0; i < zoomBy; i++) await page.getByRole('button', { name: 'Zoom in' }).click()
    const [k, size] = await canvas(page).evaluate((svg) => [
      Number(svg.querySelector('g[data-zoom]').getAttribute('data-zoom')),
      Number(svg.querySelector('[data-label]').getAttribute('font-size')),
    ])
    expect(size * k).toBeCloseTo(12, 2)
  }
  // a label sits under its node
  const n = await centre(disc(page, 'gotchas/quillfeather.md'))
  const l = await centre(node(page, 'gotchas/quillfeather.md').locator('[data-label]'))
  expect(l.y).toBeGreaterThan(n.y)
})

test('over 60 files, labels show only on hover and for the hovered node\'s neighbours', async ({ page }) => {
  const nodes = Array.from({ length: 70 }, (_, i) => {
    const id = `topic-${String(i).padStart(2, '0')}/note.md`
    return { id, folder: `topic-${String(i % 3).padStart(2, '0')}/`, rules: 1, heat: i % 5, orphan: false, core: false }
  })
  const edges = nodes.slice(1).map((n, i) => ({ source: nodes[i].id, target: n.id }))
  await page.route('**/api/graph', (route) => route.fulfill({ json: { nodes, edges, broken: [] } }))
  await openApp(page, 'graph')
  const labels = canvas(page).locator('[data-label]')
  await expect(canvas(page).locator('[data-node]')).toHaveCount(70)
  await expect(labels).toHaveCount(0)
  await disc(page, 'topic-10/note.md').hover()
  await expect(labels).toHaveCount(3)
  await expect(labels).toHaveText(['note', 'note', 'note'])
  await expect(node(page, 'topic-10/note.md').locator('[data-label]')).toHaveCount(1)
  await expect(node(page, 'topic-09/note.md').locator('[data-label]')).toHaveCount(1)
  await expect(node(page, 'topic-11/note.md').locator('[data-label]')).toHaveCount(1)
  await expect(node(page, 'topic-30/note.md').locator('[data-label]')).toHaveCount(0)
  await page.mouse.move(5, 5)
  await expect(labels).toHaveCount(0)
})

test('zoom buttons zoom in, out and reset, between 0.25x and 4x', async ({ page }) => {
  await openApp(page, 'graph')
  const zin = page.getByRole('button', { name: 'Zoom in' })
  const zout = page.getByRole('button', { name: 'Zoom out' })
  const reset = page.getByRole('button', { name: 'Reset view' })
  const k0 = await settledZoom(page)
  await zin.click()
  expect(await zoomOf(page)).toBeCloseTo(k0 * 1.3, 2)
  await zout.click()
  await zout.click()
  expect(await zoomOf(page)).toBeCloseTo(k0 / 1.3, 2)
  await reset.click()
  expect(await zoomOf(page)).toBeCloseTo(k0, 3)
  for (let i = 0; i < 12; i++) await zin.click()
  expect(await zoomOf(page)).toBe(4)
  await reset.click()
  for (let i = 0; i < 20; i++) await zout.click()
  expect(await zoomOf(page)).toBe(0.25)
  // the hint and the buttons are in the bottom corners of the canvas
  const box = await canvas(page).boundingBox()
  const hint = await page.locator('[data-hint]').boundingBox()
  const cam = await page.getByRole('group', { name: 'Camera' }).boundingBox()
  expect(hint.x).toBeLessThan(box.x + box.width / 2)
  expect(hint.y).toBeGreaterThan(box.y + box.height * 0.8)
  expect(cam.x).toBeGreaterThan(box.x + box.width / 2)
  expect(cam.y + cam.height).toBeGreaterThan(box.y + box.height * 0.9)
  await expect(page.locator('[data-hint]')).toHaveText(`${FILES.length} files · 5 links · drag to pan · scroll to zoom · click to open`)
})

test('the wheel zooms around the pointer, dragging the background pans', async ({ page }) => {
  await openApp(page, 'graph')
  const k0 = await settledZoom(page)
  const target = 'how-i-work/planning.md'
  const before = await centre(disc(page, target))
  await page.mouse.move(before.x, before.y)
  await page.mouse.wheel(0, -400)
  await expect.poll(() => zoomOf(page)).toBeGreaterThan(k0)
  const after = await centre(disc(page, target))
  expect(Math.abs(after.x - before.x), 'the point under the pointer stays put').toBeLessThanOrEqual(1.5)
  expect(Math.abs(after.y - before.y)).toBeLessThanOrEqual(1.5)
  await page.mouse.wheel(0, 4000)
  await expect.poll(() => zoomOf(page)).toBe(0.25)
  await page.mouse.wheel(0, -40000)
  await expect.poll(() => zoomOf(page)).toBe(4)
  await page.getByRole('button', { name: 'Reset view' }).click()

  // pan: grab the empty background, every node moves with it
  const start = await centre(disc(page, target))
  const box = await canvas(page).boundingBox()
  const gx = box.x + 24
  const gy = box.y + 24
  await page.mouse.move(gx, gy)
  await page.mouse.down()
  await page.mouse.move(gx + 60, gy + 35, { steps: 6 })
  await page.mouse.up()
  const moved = await centre(disc(page, target))
  expect(moved.x - start.x).toBeCloseTo(60, 0)
  expect(moved.y - start.y).toBeCloseTo(35, 0)
  expect(await zoomOf(page)).toBeCloseTo(k0, 3)
  await expect(page).toHaveURL(/#\/graph$/)
})

// Where a press that is not on a node can land: empty canvas, a label, a halo, an edge, and empty
// canvas again once the graph is zoomed out to 0.25x (the transformed background is then smaller
// than the canvas). Every one of them must pan the whole graph by the dragged distance.
test('dragging anywhere that is not a node pans the graph, over labels, halos, edges and a zoomed-out canvas', async ({ page }) => {
  await openApp(page, 'graph')
  const ref = 'how-i-work/planning.md'
  const box = await canvas(page).boundingBox()
  const notNode = (x, y) => page.evaluate(([px, py]) => !document.elementFromPoint(px, py)?.closest('[data-node]'), [x, y])

  const panFrom = async (label, at, dx = 70, dy = 40) => {
    expect(await notNode(at.x, at.y), `${label}: the press is not on a node`).toBe(true)
    const a = await centre(disc(page, ref))
    const k = await settledZoom(page)
    await page.mouse.move(at.x, at.y)
    await page.mouse.down()
    await page.mouse.move(at.x + dx, at.y + dy, { steps: 8 })
    await page.mouse.up()
    const b = await centre(disc(page, ref))
    expect(b.x - a.x, `${label}: x moved`).toBeCloseTo(dx, 0)
    expect(b.y - a.y, `${label}: y moved`).toBeCloseTo(dy, 0)
    expect(await zoomOf(page), `${label}: zoom unchanged`).toBeCloseTo(k, 6)
    await expect(page).toHaveURL(/#\/graph$/)
    // put it back for the next press
    await page.getByRole('button', { name: 'Reset view' }).click()
  }

  // (a) empty canvas near each corner
  await panFrom('top-left corner', { x: box.x + 20, y: box.y + 20 })
  await panFrom('top-right corner', { x: box.x + box.width - 20, y: box.y + 20 })
  await panFrom('bottom-left corner', { x: box.x + 20, y: box.y + box.height - 60 })

  // (b) a label: its far end, clear of its node
  const label = await node(page, 'gotchas/quillfeather.md').locator('[data-label]').boundingBox()
  await panFrom('a label', { x: label.x + 3, y: label.y + label.height / 2 })

  // (c) a halo: just outside the node's hit area, where only the glow is drawn; and an edge
  const d = await disc(page, 'safety/backups.md').boundingBox()
  const r = d.width / 2
  const c = { x: d.x + r, y: d.y + r }
  const k0 = await settledZoom(page)
  await panFrom('a halo', { x: c.x + r + 11 * k0, y: c.y - 2 })
  const edge = await canvas(page).locator('line[data-edge]').first().boundingBox()
  await panFrom('an edge', { x: edge.x + edge.width / 2, y: edge.y + edge.height / 2 })

  // (d) empty canvas after zooming out to 0.25x, near every corner and in the middle of the empty rim
  for (let i = 0; i < 20; i++) await page.getByRole('button', { name: 'Zoom out' }).click()
  expect(await zoomOf(page)).toBe(0.25)
  const small = async (label, at) => {
    expect(await notNode(at.x, at.y), `${label}: the press is not on a node`).toBe(true)
    const a = await centre(disc(page, ref))
    await page.mouse.move(at.x, at.y)
    await page.mouse.down()
    await page.mouse.move(at.x + 60, at.y + 30, { steps: 8 })
    await page.mouse.up()
    const b = await centre(disc(page, ref))
    expect(b.x - a.x, `${label}: x moved`).toBeCloseTo(60, 0)
    expect(b.y - a.y, `${label}: y moved`).toBeCloseTo(30, 0)
    expect(await zoomOf(page)).toBe(0.25)
  }
  await small('zoomed out, top-left', { x: box.x + 12, y: box.y + 12 })
  await small('zoomed out, bottom-right', { x: box.x + box.width - 80, y: box.y + box.height - 12 })
  await small('zoomed out, far right edge', { x: box.x + box.width - 12, y: box.y + box.height / 2 })
  await small('zoomed out, the middle left', { x: box.x + 12, y: box.y + box.height / 2 })
})

test('dragging a node moves it while held, then lets it go; a drag does not open the file', async ({ page }) => {
  await openApp(page, 'graph')
  const path = 'profile.md'
  const start = await centre(disc(page, path))
  const bystander = await centre(disc(page, 'how-i-work/planning.md'))
  const box = await canvas(page).boundingBox()
  const to = { x: box.x + box.width - 120, y: box.y + 90 }
  await page.mouse.move(start.x, start.y)
  await page.mouse.down()
  await page.mouse.move(to.x, to.y, { steps: 12 })
  // pinned to the pointer while held
  await expect.poll(async () => Math.hypot((await centre(disc(page, path))).x - to.x, (await centre(disc(page, path))).y - to.y)).toBeLessThanOrEqual(1.5)
  // the rest of the graph stays roughly put (the forces nudge it; a pan would move it by the whole drag, 700 px and more)
  const still = await centre(disc(page, 'how-i-work/planning.md'))
  expect(Math.hypot(still.x - bystander.x, still.y - bystander.y)).toBeLessThan(200)
  await page.mouse.up()
  await expect(page).toHaveURL(/#\/graph$/)
  // released: the forces take it again, so it does not stay where it was dropped
  await expect.poll(async () => {
    const c = await centre(disc(page, path))
    return Math.hypot(c.x - to.x, c.y - to.y)
  }, { timeout: 8000 }).toBeGreaterThan(5)
  // and a plain click still opens it
  await disc(page, 'core.md').click()
  await expect(page).toHaveURL(/#\/memory\?path=core\.md$/)
})

test('the graph fills the height of the screen', async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 })
  await openApp(page, 'graph')
  const tall = async () => (await canvas(page).boundingBox()).height
  const h900 = await tall()
  const b900 = await canvas(page).boundingBox()
  expect(b900.y + b900.height, 'reaches the bottom of the screen, less the page margin').toBeGreaterThan(900 - 48)
  expect(h900).toBeGreaterThan(600)
  await page.setViewportSize({ width: 1440, height: 1100 })
  await expect.poll(tall).toBeGreaterThan(h900 + 150)
  await page.setViewportSize({ width: 1440, height: 760 })
  await expect.poll(tall).toBeLessThan(h900 - 100)
})

test('the legend names each folder colour and each mark; orphans and broken links are listed beside the graph', async ({ page }) => {
  await openApp(page, 'graph')
  const legend = page.getByRole('region', { name: 'Legend' })
  const folders = legend.getByRole('list', { name: 'Folders' }).locator('li')
  await expect(folders).toHaveCount(Object.keys(FOLDER_COLOUR).length)
  for (const [i, [name, colour]] of Object.entries(FOLDER_COLOUR).entries()) {
    const li = folders.nth(i)
    await expect(li).toHaveAttribute('data-color', colour)
    await expect(li.locator('span').first()).toHaveCSS('background-color', hexToRgb(colour))
    const n = FILES.filter((f) => folderOf(f.path) === name).length
    await expect(li).toHaveText(`${name}${n} file${n === 1 ? '' : 's'}`)
  }
  const marks = legend.getByRole('list', { name: 'Marks' }).locator('li')
  await expect(marks).toHaveText([
    'Size grows with links in and out',
    'Core double ring',
    'Orphan red ring: no link in, no read_when',
    `Halo glows brighter the more a file is read (up to ${MAX_HEAT} reads)`,
  ])

  const orphans = page.getByRole('region', { name: 'Orphans' })
  await expect(orphans.getByRole('heading')).toHaveText('Orphans (1)')
  await expect(orphans.locator('li')).toHaveText(['gotchas/orphaned-tips.md'])
  const broken = page.getByRole('region', { name: 'Broken links' })
  await expect(broken.getByRole('heading')).toHaveText('Broken links (1)')
  await expect(broken.locator('li')).toHaveText(['gotchas/quillfeather.md links to gotchas/missing-notes.md (missing)'])
  // beside the graph: to its right, not below it
  const g = await canvas(page).boundingBox()
  const l = await legend.boundingBox()
  expect(l.x).toBeGreaterThan(g.x + g.width)
  await shot(page, 'graph')
})

test('clicking a node opens that file in Memory', async ({ page }) => {
  await openApp(page, 'graph')
  await disc(page, 'gotchas/quillfeather.md').click()
  await expect(page).toHaveURL(/#\/memory\?path=gotchas%2Fquillfeather\.md$/)
  await expect(page.getByRole('article', { name: 'gotchas/quillfeather.md' }).getByRole('heading', { level: 2 })).toHaveText('Quillfeather importer')
  await expect(page.getByRole('navigation', { name: 'Screens' }).getByRole('link', { name: 'Memory' })).toHaveAttribute('aria-current', 'page')
})

test('a node opens from the keyboard, and an orphan listed beside the graph opens in Memory too', async ({ page }) => {
  await openApp(page, 'graph')
  await node(page, 'gotchas/legacy/ferry-radio.md').focus()
  await expect(node(page, 'how-i-work/planning.md')).toHaveAttribute('opacity', '0.15')
  await page.keyboard.press('Enter')
  await expect(page.getByRole('article', { name: 'gotchas/legacy/ferry-radio.md' }).getByRole('heading', { level: 2 })).toHaveText('Ferry radio')

  await openApp(page, 'graph')
  await page.getByRole('region', { name: 'Orphans' }).getByRole('link', { name: 'gotchas/orphaned-tips.md' }).click()
  await expect(page.getByRole('article', { name: 'gotchas/orphaned-tips.md' }).getByRole('heading', { level: 2 })).toHaveText('Loose tips')
})

function hexToRgb(hex) {
  const n = parseInt(hex.slice(1), 16)
  return `rgb(${n >> 16}, ${(n >> 8) & 255}, ${n & 255})`
}
