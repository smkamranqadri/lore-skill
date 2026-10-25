// Rebuilds the app into a temporary folder and compares sorted sha256 lists with the committed
// bundle in skills/lore/ui/dist. Exits 1 and names every file that differs, is missing or is extra.
// It builds with the same config as `npm run build`; only the output folder changes.

import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

const ui = fileURLToPath(new URL('..', import.meta.url))
const committed = join(ui, '..', 'skills', 'lore', 'ui', 'dist')
const vite = join(ui, 'node_modules', 'vite', 'bin', 'vite.js')

function hashes(dir) {
  const out = new Map()
  const walk = (d) => {
    for (const name of readdirSync(d).sort()) {
      const p = join(d, name)
      if (statSync(p).isDirectory()) walk(p)
      else out.set(relative(dir, p).split('\\').join('/'), createHash('sha256').update(readFileSync(p)).digest('hex'))
    }
  }
  if (existsSync(dir)) walk(dir)
  return out
}

const tmp = mkdtempSync(join(tmpdir(), 'lore-ui-dist-'))
try {
  const built = spawnSync(process.execPath, [vite, 'build', '--outDir', tmp, '--emptyOutDir'], { cwd: ui, encoding: 'utf8' })
  if (built.status !== 0) {
    process.stderr.write(`check-dist: the rebuild failed (exit ${built.status})\n${built.stdout}${built.stderr}`)
    process.exit(2)
  }
  const want = hashes(tmp)
  const have = hashes(committed)
  const bad = []
  for (const [file, sum] of want) {
    if (!have.has(file)) bad.push(`missing from skills/lore/ui/dist: ${file}`)
    else if (have.get(file) !== sum) bad.push(`differs: ${file}`)
  }
  for (const file of have.keys()) if (!want.has(file)) bad.push(`not produced by the build: ${file}`)
  if (bad.length) {
    process.stderr.write(`check-dist: skills/lore/ui/dist is not the build of ui/\n${bad.map((b) => `  ${b}`).join('\n')}\nRun \`npm run build\` in ui/ and commit the result.\n`)
    process.exit(1)
  }
  process.stdout.write(`check-dist: ok (${want.size} files, ${[...want.values()].length} sha256 sums match)\n`)
} finally {
  rmSync(tmp, { recursive: true, force: true })
}
