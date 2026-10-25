// Builds the fictional store with the real `lore` CLI from this checkout (a temp HOME, no git
// config, a local bare repository as the hub), then starts the real `lore ui` and reads the one
// line it prints. Teardown stops it. LORE_UI_SERVER=mock starts dev/mock-server.mjs instead, for
// work done before the real server exists; the specs mark what only the real server proves.

import { spawn, spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { createInterface } from 'node:readline'
import { fileURLToPath } from 'node:url'
import {
  HAND_A, HAND_B, HARBOUR_FILE, HAND_SUBJECTS, HISTORY, LAYOUT_PROPOSAL, RETIRE, SEED, SEED_SUBJECT,
  ago, anchor, entry, ruleId,
} from './fixture-data.mjs'

const here = dirname(fileURLToPath(import.meta.url))
const uiDir = join(here, '..')
const repo = join(uiDir, '..')
const lorePy = join(repo, 'skills', 'lore', 'scripts', 'lore.py')

function cleanEnv(home) {
  const env = { ...process.env, HOME: home, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1', PYTHONDONTWRITEBYTECODE: '1', LANG: 'C.UTF-8' }
  for (const k of Object.keys(env)) if (k.startsWith('LORE_') && k !== 'LORE_E2E_TODAY') delete env[k]
  delete env.XDG_DATA_HOME
  delete env.MISE_DATA_DIR
  return env
}

const sortKeys = (v) =>
  Array.isArray(v) ? v.map(sortKeys) : v && typeof v === 'object' ? Object.fromEntries(Object.keys(v).sort().map((k) => [k, sortKeys(v[k])])) : v
const dumpMeta = (data) => JSON.stringify(sortKeys(data), null, 1) + '\n'

export default async function globalSetup() {
  const mock = process.env.LORE_UI_SERVER === 'mock'
  process.env.LORE_E2E_TODAY = anchor()
  const tmp = mkdtempSync(join(tmpdir(), 'lore-ui-e2e-'))
  const home = join(tmp, 'home')
  const store = join(tmp, 'store')
  const hub = join(tmp, 'hub.git')
  mkdirSync(home)
  const env = cleanEnv(home)
  const state = { tmp, home, store, hub, mock, anchor: anchor(), server: mock ? 'mock' : 'real' }
  if (mock) state.ids = { handA: 'h-2946be1e', handB: 'h-46785a3e', retire: 'r-691dffcb', layout: 'p-e98a724c' }

  const run = (cmd, args, opts = {}) => {
    const res = spawnSync(cmd, args, { env, encoding: 'utf8', cwd: tmp, timeout: 120_000, ...opts })
    if (res.status !== 0) throw new Error(`${cmd} ${args.join(' ')} exited ${res.status}\n${res.stdout}\n${res.stderr}`)
    return res.stdout
  }
  const lore = (...args) => run('python3', [lorePy, '--store2', store, ...args])
  const git = (...args) => run('git', ['-C', store, ...args])

  if (!mock) {
    run('git', ['init', '-q', '--bare', '-b', 'main', hub])
    lore('store', 'init')
    lore('hub', 'set', hub)

    // the model: path -> file text and sidecar, written out after each step
    const model = new Map()
    const put = (f) => {
      model.set(f.path, f)
      mkdirSync(dirname(join(store, f.path)), { recursive: true })
      writeFileSync(join(store, f.path), `# ${f.title}\n\n` + f.rules.map((x) => `- ${x.text}\n`).join(''))
      const meta = { links: [...f.links].sort(), reads: f.reads, last_read: Object.fromEntries(Object.entries(f.lastReadAgo).map(([m, n]) => [m, ago(n)])), rules: Object.fromEntries(f.rules.map((x) => entry(x, x.id))) }
      if (f.readWhen) Object.assign(meta, { read_when: f.readWhen, read_when_updated: `${ago(20)}T09:00:00+00:00` })
      mkdirSync(dirname(join(store, '.lore', 'meta', f.path)), { recursive: true })
      writeFileSync(join(store, '.lore', 'meta', f.path.replace(/\.md$/, '.json')), dumpMeta(meta))
    }
    for (const f of SEED) put({ ...f, rules: f.rules.map((x) => ({ ...x, id: ruleId(x.text) })) })
    lore('store', 'commit', '-m', SEED_SUBJECT)

    for (const h of HISTORY) {
      const f = model.get(h.file) ?? { ...HARBOUR_FILE, rules: [] }
      if (h.add) f.rules.push({ text: h.add, count: 1, explicit: false, createdAgo: h.createdAgo ?? 1, datesAgo: [h.createdAgo ?? 1], id: ruleId(h.add) })
      if (h.reword) f.rules.find((x) => x.text === h.reword[0]).text = h.reword[1]
      put(f)
      lore('store', 'commit', '-m', h.subject)
    }

    // two hand edits: a rule line with no sidecar entry, which the next commit adopts and flags
    for (const [i, h] of [HAND_A, HAND_B].entries()) {
      const p = join(store, h.file)
      writeFileSync(p, readFileSync(p, 'utf8') + `- ${h.text}\n`)
      lore('store', 'commit', '-m', HAND_SUBJECTS[i])
    }

    // a layout proposal and a retirement, the two kinds nothing above produced
    mkdirSync(join(store, '.git', 'lore', 'proposals'), { recursive: true })
    writeFileSync(join(store, '.git', 'lore', 'proposals', 'proposal-tools.json'), JSON.stringify({ top: LAYOUT_PROPOSAL }) + '\n')
    mkdirSync(join(store, '.git', 'lore', 'inbox'), { recursive: true })
    const payload = { file: RETIRE.file, rule_id: ruleId(RETIRE.text), text: RETIRE.text, reason: RETIRE.reason }
    const rid = 'r-' + createHash('sha1').update(JSON.stringify(payload)).digest('hex').slice(0, 8)
    writeFileSync(join(store, '.git', 'lore', 'inbox', `${rid}.json`), JSON.stringify({ id: rid, kind: 'retire', created: `${anchor()}T08:00:00+00:00`, payload, source: 'canon' }) + '\n')

    const list = lore('inbox', 'list')
    state.inboxList = list
    const ids = {}
    for (const line of list.split('\n')) {
      const m = /^(\S+)  (\S+)  (.*)$/.exec(line)
      if (!m) continue
      const [, id, kind, summary] = m
      if (kind === 'hand-edit') ids[summary.includes(HAND_A.text) ? 'handA' : 'handB'] = id
      else ids[kind] = id
    }
    state.ids = ids
    state.head = git('rev-parse', 'HEAD').trim()
  }

  // the server
  const args = mock ? [join(uiDir, 'dev', 'mock-server.mjs'), '--port', '0'] : [lorePy, '--store2', store, 'ui']
  const child = spawn(mock ? process.execPath : 'python3', args, { env, cwd: tmp, stdio: ['ignore', 'pipe', 'pipe'] })
  const stderr = []
  child.stderr.on('data', (b) => stderr.push(String(b)))
  const url = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`the server printed no URL in 20 s\n${stderr.join('')}`)), 20_000)
    createInterface({ input: child.stdout }).on('line', (line) => {
      const m = /^lore ui: (http:\/\/127\.0\.0\.1:\d+\/#t=[A-Za-z0-9_-]+)$/.exec(line)
      if (m) {
        clearTimeout(timer)
        resolve(m[1])
      }
    })
    child.on('exit', (code) => {
      clearTimeout(timer)
      reject(new Error(`the server exited ${code} before printing its URL\n${stderr.join('')}`))
    })
  })
  state.url = url
  state.serverPid = child.pid
  process.env.LORE_E2E_STATE = join(tmp, 'state.json')
  writeFileSync(process.env.LORE_E2E_STATE, JSON.stringify(state, null, 1))

  return async () => {
    child.removeAllListeners('exit')
    const gone = new Promise((resolve) => child.once('exit', resolve))
    child.kill('SIGTERM')
    const hard = setTimeout(() => child.kill('SIGKILL'), 5000)
    await gone
    clearTimeout(hard)
    if (!process.env.KEEP) rmSync(tmp, { recursive: true, force: true })
  }
}
