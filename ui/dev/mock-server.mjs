// A fixture-backed stand-in for `lore ui`, for work done before the real server exists. It answers
// the P4a contract's shapes from tests/fixture-data.mjs, keeps its writes in memory and enforces
// the same Host, token, header and error rules. It is never part of the bundle. Usage:
//   node dev/mock-server.mjs [--port N]      (default 3899; 0 picks a free port)
// Extra, mock only: POST /__mock/busy {"on": true} makes every write answer 409 busy, and
// POST /__mock/pushfail {"on": true} makes every write's push fail (a 200 with "pushed": false).
// POST /__mock/nohub {"on": true} answers as a store with no hub (the push line says so, "pushed": null).

import { createHash, randomBytes, timingSafeEqual } from 'node:crypto'
import { createServer } from 'node:http'
import { existsSync, readFileSync, statSync } from 'node:fs'
import { extname, join, normalize, sep } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  HAND_A, HAND_B, HISTORY, INIT_SUBJECT, LAYOUT_PROPOSAL, RETIRE, SEED_SUBJECT, HAND_SUBJECTS,
  TOP, ago, anchor, finalFiles, lastDateOf, lastReadOf, readsOf, ruleId,
} from '../tests/fixture-data.mjs'

const dist = fileURLToPath(new URL('../../skills/lore/ui/dist/', import.meta.url))
const argPort = process.argv.indexOf('--port')
const wantPort = argPort > 0 ? Number(process.argv[argPort + 1]) : 3899
const token = randomBytes(32).toString('base64url')
const sha = (s) => createHash('sha1').update(s).digest('hex')

// ---- the world ---------------------------------------------------------------------------------
const files = finalFiles()
const world = {
  busy: false,
  pushFail: false,
  noHub: false,
  files,
  inbox: [
    { id: 'h-2946be1e', kind: 'hand-edit', created: anchor(), payload: { file: HAND_A.file, rule_id: ruleId(HAND_A.text), text: HAND_A.text }, source: 'hand edit' },
    { id: 'h-46785a3e', kind: 'hand-edit', created: anchor(), payload: { file: HAND_B.file, rule_id: ruleId(HAND_B.text), text: HAND_B.text }, source: 'hand edit' },
    { id: 'r-691dffcb', kind: 'retire', created: `${anchor()}T08:00:00+00:00`, payload: { file: RETIRE.file, rule_id: ruleId(RETIRE.text), text: RETIRE.text, reason: RETIRE.reason }, source: 'canon' },
    { id: 'p-e98a724c', kind: 'layout', created: `${anchor()}T08:30:00+00:00`, payload: { top: LAYOUT_PROPOSAL }, source: 'hub merge' },
  ],
  commits: [],
}
const summaryOf = (it) => {
  const p = it.payload
  const what = it.kind === 'layout' ? 'top: ' + p.top.join(', ') : `${p.file} ${p.rule_id}: ${p.text || p.reason || ''}`
  return what.slice(0, 160)
}

const plan = [
  { subject: INIT_SUBJECT, kind: 'owner', files: ['.gitattributes', '.gitignore', '.lore/config', '.lore/layout.json', 'core.md', 'profile.md'], root: true },
  { subject: SEED_SUBJECT, kind: 'owner', files: finalFiles().map((f) => f.path) },
  ...HISTORY.map((h) => ({ subject: h.subject, kind: h.kind, files: [h.file], add: h.add, reword: h.reword })),
  { subject: HAND_SUBJECTS[0], kind: 'owner', files: [HAND_A.file], add: HAND_A.text },
  { subject: HAND_SUBJECTS[1], kind: 'owner', files: [HAND_B.file], add: HAND_B.text },
]
plan.forEach((p, i) => world.commits.push({ ...p, sha: sha(`${i}:${p.subject}`), date: `${ago(plan.length - i)}T10:${String(i).padStart(2, '0')}:00+00:00` }))
const newest = () => world.commits[world.commits.length - 1]

function commitRow(c) {
  return { sha: c.sha, short: c.sha.slice(0, 7), date: c.date, subject: c.subject, kind: c.kind, files: c.files }
}
function diffOf(c) {
  const out = []
  for (const f of c.files.filter((x) => x.endsWith('.md'))) {
    out.push(`diff --git a/${f} b/${f}`, 'index 1111111..2222222 100644', `--- a/${f}`, `+++ b/${f}`, '@@ -1,2 +1,3 @@', ' # Heading', ' ')
    if (c.reword) out.push(`-- ${c.reword[0]}`, `+- ${c.reword[1]}`)
    else if (c.add) out.push(`+- ${c.add}`)
    else out.push('+- (the seed rules)')
  }
  return out.join('\n') + '\n'
}

// ---- routes ------------------------------------------------------------------------------------
class HttpError extends Error {
  constructor(status, code, message) {
    super(message)
    this.status = status
    this.code = code
  }
}
const rulesText = (f) => `# ${f.title}\n\n` + f.rules.map((x) => `- ${x.text}\n`).join('')

function memory() {
  return {
    top: TOP,
    files: world.files.map((f) => ({
      path: f.path, title: f.title, read_when: f.readWhen, rules: f.rules.length, chars: rulesText(f).length,
      reads: readsOf(f), last_read: lastReadOf(f), links: f.links, core: f.path === 'core.md', lint: f.expectLint ?? [],
    })),
    outside_layout: [],
  }
}
function fileDetail(path) {
  const f = world.files.find((x) => x.path === path)
  if (!f) throw new HttpError(404, 'not_found', 'no such rule file')
  return {
    path: f.path, title: f.title, read_when: f.readWhen, links: f.links, reads: f.reads,
    last_read: Object.fromEntries(Object.entries(f.lastReadAgo).map(([m, n]) => [m, ago(n)])),
    rules: f.rules.map((x) => ({
      id: ruleId(x.text), text: x.text, count: x.count, explicit: x.explicit, created: ago(x.createdAgo),
      dates: x.datesAgo.map(ago).sort(), confidence: x.explicit ? 0.9 : 0.7, updated: `${ago(x.createdAgo)}T09:00:00+00:00`,
      quote: null, hand_edit: f.hand.includes(x.text) ? anchor() : null, contradictions: [],
    })),
  }
}
function graph() {
  const have = new Set(world.files.map((f) => f.path))
  const incoming = new Set(world.files.flatMap((f) => f.links.filter((l) => have.has(l) && l !== f.path)))
  const edges = []
  const broken = []
  for (const f of world.files) for (const l of f.links) (have.has(l) ? edges : broken).push({ source: f.path, target: l })
  return {
    nodes: world.files.map((f) => ({
      id: f.path, folder: f.path === 'core.md' ? 'core.md' : TOP.find((t) => (t.endsWith('/') ? f.path.startsWith(t) : f.path === t)),
      rules: f.rules.length, heat: readsOf(f), orphan: f.path !== 'core.md' && !incoming.has(f.path) && !f.readWhen, core: f.path === 'core.md',
    })),
    edges, broken,
  }
}
function changes(q) {
  const limit = Math.min(200, Math.max(1, Number(q.get('limit') ?? 50)))
  let list = [...world.commits].reverse()
  if (q.get('before')) {
    const i = list.findIndex((c) => c.sha === q.get('before'))
    if (i < 0) throw new HttpError(404, 'not_found', 'unknown commit')
    list = list.slice(i + 1)
  }
  const page = list.slice(0, limit)
  return { commits: page.map(commitRow), next: list.length > limit ? page[page.length - 1].sha : null }
}
function commit(q) {
  const i = world.commits.findIndex((c) => c.sha === q.get('sha'))
  if (i < 0) throw new HttpError(404, 'not_found', 'unknown commit')
  const c = world.commits[i]
  return {
    ...commitRow(c), body: '',
    files: c.files.map((p) => ({ path: p, status: c.root || c.subject === SEED_SUBJECT ? 'A' : 'M' })),
    diff: diffOf(c), truncated: false,
    meta_changed: c.files.filter((f) => f.endsWith('.md')).map((f) => '.lore/meta/' + f.replace(/\.md$/, '.json')),
  }
}
function write(fn) {
  if (world.busy) throw new HttpError(409, 'busy', 'lore is busy')
  return fn()
}
function addCommit(subject, kind, extra = {}) {
  const c = { subject, kind, files: [], sha: sha(`${world.commits.length}:${subject}:${Date.now()}`), date: new Date().toISOString().replace(/\.\d+Z$/, '+00:00'), ...extra }
  world.commits.push(c)
  return c
}
// Amendment 1: pushed is true (pushed), false (a hub is set and the push failed) or null (no hub).
function pushLine() {
  if (world.noHub) return { push: 'hub: none (local git only)', pushed: null }
  return world.pushFail
    ? { push: 'hub: push FAILED (committed locally; the next run retries)', pushed: false }
    : { push: 'hub: pushed to /tmp/mock/hub.git', pushed: true }
}
function inboxAct(action, body) {
  const i = world.inbox.findIndex((x) => x.id === body.id)
  if (i < 0) throw new HttpError(404, 'not_found', `no inbox item ${String(body.id).slice(0, 40)}`)
  const item = world.inbox[i]
  const file = item.payload.file && world.files.find((f) => f.path === item.payload.file)
  let c = null
  if (item.kind === 'hand-edit' && file) {
    if (action === 'accept') file.hand = file.hand.filter((t) => t !== item.payload.text)
    else {
      file.rules = file.rules.filter((x) => x.text !== item.payload.text)
      file.hand = file.hand.filter((t) => t !== item.payload.text)
    }
    c = addCommit(`inbox: ${action === 'accept' ? 'keep' : 'reject'} hand edit ${ruleId(item.payload.text)} in ${file.path}`, 'inbox', { files: [file.path] })
  } else if (action === 'accept') {
    if (item.kind === 'retire' && file) file.rules = file.rules.filter((x) => x.text !== item.payload.text)
    c = addCommit(`inbox: ${item.kind === 'retire' ? 'retire' : 'accept layout'} ${item.id}`, 'inbox', { files: [item.kind === 'retire' ? file.path : '.lore/layout.json'] })
  }
  world.inbox.splice(i, 1)
  return action === 'accept'
    ? { ok: true, kind: item.kind, commit: c?.sha ?? null, ...pushLine() }
    : { ok: true, commit: c?.sha ?? null, ...(c ? pushLine() : { push: null, pushed: null }) }
}
// ---- http --------------------------------------------------------------------------------------
const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.json': 'application/json' }
const CSP = "default-src 'self'; img-src 'self' data:; frame-ancestors 'none'"

function send(res, status, body, type, extra = {}) {
  res.writeHead(status, { 'Content-Type': type, 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer', 'Content-Security-Policy': CSP, ...extra })
  res.end(body)
}
const json = (res, status, data) => send(res, status, JSON.stringify(data), 'application/json; charset=utf-8', { 'Cache-Control': 'no-store' })

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = []
    let n = 0
    req.on('data', (b) => {
      n += b.length
      if (n > 64 * 1024) reject(new HttpError(400, 'bad_request', 'body too large'))
      else chunks.push(b)
    })
    req.on('end', () => {
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}'))
      } catch {
        reject(new HttpError(400, 'bad_request', 'body is not JSON'))
      }
    })
  })
}

function tokenOk(h) {
  const a = Buffer.from(String(h ?? ''))
  const b = Buffer.from(token)
  return a.length === b.length && timingSafeEqual(a, b)
}

const server = createServer(async (req, res) => {
  const port = server.address().port
  const url = new URL(req.url ?? '/', `http://127.0.0.1:${port}`)
  try {
    if (![`127.0.0.1:${port}`, `localhost:${port}`].includes(req.headers.host ?? '') && !process.env.MOCK_ANY_HOST) {
      throw new HttpError(403, 'forbidden', 'forbidden host')
    }
    if (req.method === 'OPTIONS') throw new HttpError(405, 'bad_request', 'method not allowed')
    if (url.pathname.startsWith('/api/') || url.pathname.startsWith('/__mock/')) {
      if (!tokenOk(req.headers['x-lore-token'])) throw new HttpError(401, 'unauthorized', 'unauthorized')
      const q = url.searchParams
      if (req.method === 'POST') {
        if (!String(req.headers['content-type'] ?? '').startsWith('application/json')) throw new HttpError(415, 'unsupported', 'POST needs application/json')
        const body = await readBody(req)
        if (url.pathname === '/__mock/busy' || url.pathname === '/__mock/pushfail' || url.pathname === '/__mock/nohub') {
          world[{ '/__mock/busy': 'busy', '/__mock/pushfail': 'pushFail', '/__mock/nohub': 'noHub' }[url.pathname]] = body.on === true
          return json(res, 200, { ok: true })
        }
        if (url.pathname === '/api/inbox/accept') return json(res, 200, write(() => inboxAct('accept', body)))
        if (url.pathname === '/api/inbox/reject') return json(res, 200, write(() => inboxAct('reject', body)))
        throw new HttpError(404, 'not_found', 'no such route')
      }
      const routes = {
        '/api/summary': () => ({
          store: '/tmp/mock/store', machine: 'mock-machine', version: '2.0.0-p4a', head: newest().sha.slice(0, 7),
          hub: world.noHub ? { url: null, last_push: null, push_fails: 0 } : { url: '/tmp/mock/hub.git', last_push: newest().date, push_fails: 0 },
          counts: { files: world.files.length, rules: world.files.reduce((n, f) => n + f.rules.length, 0), inbox: world.inbox.length },
        }),
        '/api/memory': memory,
        '/api/file': () => fileDetail(q.get('path')),
        '/api/graph': graph,
        '/api/inbox': () => ({ items: world.inbox.map((it) => ({ ...it, summary: summaryOf(it) })) }),
        '/api/changes': () => changes(q),
        '/api/commit': () => commit(q),
      }
      const route = routes[url.pathname]
      if (!route) throw new HttpError(404, 'not_found', 'no such route')
      return json(res, 200, route())
    }
    // static: index.html at /, files under /assets/
    let file = null
    if (url.pathname === '/') file = join(dist, 'index.html')
    else if (url.pathname.startsWith('/assets/')) {
      const p = normalize(join(dist, decodeURIComponent(url.pathname)))
      if (p.startsWith(dist + 'assets' + sep) && existsSync(p) && statSync(p).isFile()) file = p
    }
    if (url.pathname === '/' && !existsSync(file)) return send(res, 503, 'lore ui: the UI bundle is not built', 'text/plain; charset=utf-8')
    if (!file) throw new HttpError(404, 'not_found', 'not found')
    send(res, 200, readFileSync(file), TYPES[extname(file)] ?? 'application/octet-stream', file.endsWith('index.html') ? { 'Cache-Control': 'no-store' } : {})
  } catch (e) {
    const err = e instanceof HttpError ? e : new HttpError(500, 'internal', 'internal error')
    json(res, err.status, { error: err.message, code: err.code })
  }
})

server.listen(wantPort, '127.0.0.1', () => {
  const port = server.address().port
  process.stdout.write(`lore ui: http://127.0.0.1:${port}/#t=${token}\n`)
})
for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => server.close(() => process.exit(0)))
