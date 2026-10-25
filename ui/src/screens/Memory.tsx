import { useEffect, useMemo, useRef, useState, type KeyboardEvent } from 'react'
import { Badge, ErrorBox, Loading, PageHeader } from '../components'
import { day, lastDate, plural } from '../format'
import { Icon } from '../icons'
import { href, useRoute } from '../route'
import type { FileDetail, MemoryFile, MemoryList, Rule } from '../types'
import { useApi } from '../useApi'

interface DirNode {
  kind: 'dir'
  key: string
  path: string
  name: string
  children: TreeNode[]
  files: number
  rules: number
}
interface FileNode {
  kind: 'file'
  key: string
  file: MemoryFile
}
type TreeNode = DirNode | FileNode

/**
 * core.md first, then the layout's top entries in the layout's order. Inside a folder, sub-folders
 * come before files, both in the order the API gives them.
 */
function buildTree(list: MemoryList): TreeNode[] {
  const roots: TreeNode[] = []
  const dirs = new Map<string, DirNode>()
  const topRank = (path: string) => {
    if (path === 'core.md') return -1
    const i = list.top.findIndex((t) => (t.endsWith('/') ? path.startsWith(t) : path === t))
    return i === -1 ? list.top.length : i
  }
  const ordered = [...list.files].sort((a, b) => topRank(a.path) - topRank(b.path))
  for (const file of ordered) {
    const parts = file.path.split('/')
    let siblings = roots
    for (let i = 0; i < parts.length - 1; i++) {
      const path = parts.slice(0, i + 1).join('/')
      let dir = dirs.get(path)
      if (!dir) {
        dir = { kind: 'dir', key: `dir:${path}`, path, name: parts[i], children: [], files: 0, rules: 0 }
        dirs.set(path, dir)
        siblings.push(dir)
      }
      dir.files += 1
      dir.rules += file.rules
      siblings = dir.children
    }
    siblings.push({ kind: 'file', key: file.path, file })
  }
  // sub-folders before files inside a folder; the root keeps the layout's order
  for (const dir of dirs.values()) dir.children.sort((a, b) => Number(b.kind === 'dir') - Number(a.kind === 'dir'))
  return roots
}

interface Row {
  node: TreeNode
  depth: number
  parent: string | null
}

function visibleRows(nodes: TreeNode[], collapsed: Set<string>, depth = 0, parent: string | null = null, out: Row[] = []): Row[] {
  for (const node of nodes) {
    out.push({ node, depth, parent })
    if (node.kind === 'dir' && !collapsed.has(node.key)) visibleRows(node.children, collapsed, depth + 1, node.key, out)
  }
  return out
}

const sum = (files: MemoryFile[], pick: (f: MemoryFile) => number) => files.reduce((n, f) => n + pick(f), 0)

const INDENT = 18 // px per level; the guide lines sit under the parent's chevron

function LintBadges({ gates }: { gates: string[] }) {
  return (
    <>
      {gates.map((g) => (
        <Badge key={g} className="bg-amber-50 text-amber-800 ring-amber-300" title={`lint: ${g}`}>
          <Icon name="alert" className="size-3" />
          {g}
        </Badge>
      ))}
    </>
  )
}

function Guides({ depth }: { depth: number }) {
  return (
    <>
      {Array.from({ length: depth }, (_, i) => (
        <span key={i} data-guide="" aria-hidden="true" className="pointer-events-none absolute inset-y-0 w-px bg-stone-300" style={{ left: 16 + i * INDENT }} />
      ))}
    </>
  )
}

function TreeRow({
  row,
  open,
  selected,
  tabbable,
  onToggle,
  onFocus,
}: {
  row: Row
  open: boolean
  selected: boolean
  tabbable: boolean
  onToggle: (key: string) => void
  onFocus: (key: string) => void
}) {
  const { node, depth } = row
  const pad = { paddingLeft: 8 + depth * INDENT }
  if (node.kind === 'dir') {
    return (
      <li role="none" className="relative">
        <Guides depth={depth} />
        <div
          role="treeitem"
          tabIndex={tabbable ? 0 : -1}
          aria-level={depth + 1}
          aria-expanded={open}
          aria-label={node.path}
          data-key={node.key}
          data-folder={node.path}
          data-depth={depth}
          onClick={() => onToggle(node.key)}
          onFocus={() => onFocus(node.key)}
          style={pad}
          className="flex cursor-pointer select-none items-center gap-1.5 rounded-md py-1.5 pr-3 hover:bg-stone-100 focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-indigo-600"
        >
          <Icon name="chevron" className={`size-4 shrink-0 text-stone-500 transition-transform ${open ? 'rotate-90' : ''}`} />
          <Icon name="folder" className="size-4 shrink-0 text-amber-600" />
          <span data-name="" className="min-w-0 flex-1 truncate text-sm font-semibold text-stone-900">
            {node.name}
          </span>
          <span data-counts="" className="shrink-0 text-xs tabular-nums text-stone-500">
            {plural(node.files, 'file')} · {plural(node.rules, 'rule')}
          </span>
        </div>
      </li>
    )
  }
  const { file } = node
  return (
    <li role="none" className="relative">
      <Guides depth={depth} />
      <a
        role="treeitem"
        href={href('memory', { path: file.path })}
        tabIndex={tabbable ? 0 : -1}
        aria-level={depth + 1}
        aria-selected={selected}
        aria-current={selected ? 'true' : undefined}
        aria-label={file.path}
        data-key={node.key}
        data-path={file.path}
        data-depth={depth}
        title={`${file.title}: ${file.path}`}
        onFocus={() => onFocus(node.key)}
        style={pad}
        className={`flex items-center gap-1.5 rounded-md py-1.5 pr-3 focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-indigo-600 ${selected ? 'bg-indigo-50 ring-1 ring-inset ring-indigo-200' : 'hover:bg-stone-100'}`}
      >
        <span className="size-4 shrink-0" />
        <Icon name={file.core ? 'core' : 'file'} className={`size-4 shrink-0 ${file.core ? 'text-amber-500' : 'text-stone-500'}`} />
        <span data-name="" className="min-w-0 flex-1 truncate text-sm font-medium text-stone-900">
          {file.path.replace(/^.*\//, '')}
        </span>
        <LintBadges gates={file.lint} />
        <span data-reads="" className="inline-flex shrink-0 items-center gap-1 text-xs tabular-nums text-stone-500" title="times an agent read this file">
          <Icon name="eye" className="size-3.5" />
          {file.reads}
        </span>
        <span data-rules="" className="w-14 shrink-0 text-right text-xs tabular-nums text-stone-600" title="rules">
          {plural(file.rules, 'rule')}
        </span>
      </a>
    </li>
  )
}

function Tree({ list, selected }: { list: MemoryList; selected: string | null }) {
  const nodes = useMemo(() => buildTree(list), [list])
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set())
  const [active, setActive] = useState<string | null>(null)
  const listRef = useRef<HTMLUListElement>(null)

  // opening a file from a link or the graph shows it: its folders open
  useEffect(() => {
    if (!selected) return
    const parts = selected.split('/')
    const keys = parts.slice(0, -1).map((_, i) => `dir:${parts.slice(0, i + 1).join('/')}`)
    setCollapsed((prev) => (keys.some((k) => prev.has(k)) ? new Set([...prev].filter((k) => !keys.includes(k))) : prev))
  }, [selected])

  const rows = useMemo(() => visibleRows(nodes, collapsed), [nodes, collapsed])
  const tabKey = rows.some((r) => r.node.key === active) ? active : rows.some((r) => r.node.key === selected) ? selected : rows[0]?.node.key

  const toggle = (key: string, force?: boolean) =>
    setCollapsed((prev) => {
      const next = new Set(prev)
      const open = force ?? prev.has(key)
      if (open) next.delete(key)
      else next.add(key)
      return next
    })

  const focusKey = (key: string | undefined) => {
    if (!key) return
    listRef.current?.querySelector<HTMLElement>(`[data-key="${CSS.escape(key)}"]`)?.focus()
  }

  const onKeyDown = (e: KeyboardEvent<HTMLUListElement>) => {
    const key = (e.target as HTMLElement).closest<HTMLElement>('[role=treeitem]')?.dataset.key
    const i = rows.findIndex((r) => r.node.key === key)
    if (i === -1) return
    const row = rows[i]
    const isDir = row.node.kind === 'dir'
    const isOpen = isDir && !collapsed.has(row.node.key)
    const go = (target: string | undefined) => {
      e.preventDefault()
      focusKey(target)
    }
    switch (e.key) {
      case 'ArrowDown':
        return go(rows[i + 1]?.node.key)
      case 'ArrowUp':
        return go(rows[i - 1]?.node.key)
      case 'Home':
        return go(rows[0]?.node.key)
      case 'End':
        return go(rows[rows.length - 1]?.node.key)
      case 'ArrowRight':
        if (!isDir) return
        e.preventDefault()
        if (!isOpen) toggle(row.node.key, true)
        else if (rows[i + 1]?.parent === row.node.key) focusKey(rows[i + 1].node.key)
        return
      case 'ArrowLeft':
        e.preventDefault()
        if (isOpen) toggle(row.node.key, false)
        else if (row.parent) focusKey(row.parent)
        return
      case 'Enter':
      case ' ':
        if (isDir) {
          e.preventDefault()
          toggle(row.node.key)
        } else if (e.key === ' ') {
          e.preventDefault()
          ;(e.target as HTMLElement).click()
        }
    }
  }

  return (
    <ul ref={listRef} role="tree" aria-label="Memory tree" onKeyDown={onKeyDown}>
      {rows.map((row) => (
        <TreeRow
          key={row.node.key}
          row={row}
          open={row.node.kind === 'dir' && !collapsed.has(row.node.key)}
          selected={row.node.kind === 'file' && row.node.key === selected}
          tabbable={row.node.key === tabKey}
          onToggle={(k) => toggle(k)}
          onFocus={setActive}
        />
      ))}
    </ul>
  )
}

function RuleCard({ rule }: { rule: Rule }) {
  return (
    <li className="rounded-xl border border-stone-200 bg-white p-4">
      <p className="text-[15px] leading-relaxed text-stone-900">{rule.text}</p>
      <div className="mt-3 flex flex-wrap items-center gap-x-4 gap-y-1.5 text-xs text-stone-600">
        <Badge className="bg-stone-100 text-stone-700 ring-stone-300" title="how many times this was said or seen">
          count ×{rule.count}
        </Badge>
        {rule.explicit && (
          <Badge className="bg-indigo-50 text-indigo-700 ring-indigo-200" title="stated outright by the owner">
            <Icon name="pin" className="size-3" />
            explicit
          </Badge>
        )}
        {rule.hand_edit && (
          <Badge className="bg-emerald-50 text-emerald-700 ring-emerald-200" title="written by hand, waiting in the Inbox">
            <Icon name="pencil" className="size-3" />
            hand edit {day(rule.hand_edit)}
          </Badge>
        )}
        {rule.contradictions.length > 0 && (
          <Badge className="bg-rose-50 text-rose-700 ring-rose-200">{plural(rule.contradictions.length, 'contradiction')}</Badge>
        )}
        <span>
          created <span className="font-medium text-stone-800">{day(rule.created)}</span>
        </span>
        <span>
          last <span className="font-medium text-stone-800">{lastDate(rule.dates) || day(rule.created)}</span>
        </span>
        {rule.confidence !== null && <span>confidence {rule.confidence}</span>}
        <span className="font-mono text-stone-400">{rule.id}</span>
      </div>
    </li>
  )
}

/** A path that was asked for and is not in the store: said plainly, never swapped for another file. */
function MissingFile({ path }: { path: string }) {
  return (
    <article aria-label={path} data-missing-file={path} className="space-y-3 rounded-xl border border-dashed border-stone-300 p-6">
      <h2 className="flex items-center gap-2 text-xl font-semibold text-stone-900">
        <Icon name="broken" className="size-5 text-amber-600" />
        This file does not exist
      </h2>
      <p className="font-mono text-sm text-stone-600">{path}</p>
      <p className="text-sm text-stone-600">The link or bookmark points at a file that is not in the store. Pick a file from the list.</p>
    </article>
  )
}

function FileView({ path, known }: { path: string; known: Set<string> }) {
  const { data, error, loading, reload } = useApi<FileDetail>(`/api/file?path=${encodeURIComponent(path)}`)
  if (error) return <ErrorBox message={error} onRetry={reload} />
  if (!data || loading) return <Loading what={path} />
  const machines = Object.keys(data.reads).sort()
  return (
    <article aria-label={data.path} className="space-y-5">
      <div>
        <h2 className="text-xl font-semibold text-stone-900">{data.title}</h2>
        <p className="font-mono text-sm text-stone-500">{data.path}</p>
      </div>
      <dl className="grid grid-cols-[8rem_1fr] gap-x-4 gap-y-2 rounded-xl border border-stone-200 bg-white p-4 text-sm">
        <dt className="font-medium text-stone-600">Read when</dt>
        <dd className="text-stone-900">{data.read_when ?? <span className="text-stone-500">not set</span>}</dd>
        <dt className="font-medium text-stone-600">Reads</dt>
        <dd className="text-stone-900">
          {machines.length === 0 ? (
            <span className="text-stone-500">never read</span>
          ) : (
            <ul className="flex flex-wrap gap-x-5 gap-y-1">
              {machines.map((m) => (
                <li key={m}>
                  <span className="font-medium">{m}</span>: {data.reads[m]}
                  {data.last_read[m] ? <span className="text-stone-500"> (last {day(data.last_read[m])})</span> : null}
                </li>
              ))}
            </ul>
          )}
        </dd>
        <dt className="font-medium text-stone-600">Links</dt>
        <dd>
          {data.links.length === 0 ? (
            <span className="text-stone-500">none</span>
          ) : (
            <ul className="flex flex-wrap gap-2">
              {data.links.map((l) => (
                <li key={l}>
                  {known.has(l) ? (
                    <a href={href('memory', { path: l })} className="inline-flex items-center gap-1 rounded-md bg-indigo-50 px-2 py-0.5 font-mono text-xs text-indigo-700 ring-1 ring-inset ring-indigo-200 hover:bg-indigo-100">
                      <Icon name="link" className="size-3" />
                      {l}
                    </a>
                  ) : (
                    // a link to a file that is not in the store: shown, never followed
                    <span data-missing={l} title="this file does not exist" className="inline-flex items-center gap-1 rounded-md bg-amber-50 px-2 py-0.5 font-mono text-xs text-amber-800 ring-1 ring-inset ring-amber-300">
                      <Icon name="broken" className="size-3" />
                      {l}
                      <span className="font-sans">(missing)</span>
                    </span>
                  )}
                </li>
              ))}
            </ul>
          )}
        </dd>
      </dl>
      <section aria-label="Rules">
        <h3 className="mb-2 text-sm font-semibold uppercase tracking-wide text-stone-600">{plural(data.rules.length, 'rule')}</h3>
        {data.rules.length === 0 ? (
          <p className="rounded-xl border border-dashed border-stone-300 p-6 text-center text-sm text-stone-500">No rules in this file yet.</p>
        ) : (
          <ul className="space-y-3">
            {data.rules.map((r) => (
              <RuleCard key={r.id} rule={r} />
            ))}
          </ul>
        )}
      </section>
    </article>
  )
}

export default function Memory() {
  const { params } = useRoute()
  const { data, error, loading, reload } = useApi<MemoryList>('/api/memory')
  if (error) return <ErrorBox message={error} onRetry={reload} />
  if (!data || loading) return <Loading what="memory" />

  const wanted = params.get('path')
  // a path that was asked for and is not listed opens nothing else; only no path at all opens the first file
  const missing = wanted && !data.files.some((f) => f.path === wanted) ? wanted : null
  const selected = missing ? null : (wanted || data.files[0]?.path || null)
  const known = new Set(data.files.map((f) => f.path))
  const totalRules = sum(data.files, (f) => f.rules)

  return (
    <div className="px-8 py-6">
      <PageHeader title="Memory" subtitle={`${plural(data.files.length, 'file')}, ${plural(totalRules, 'rule')}. Read-only.`} />
      <div className="mt-5 grid grid-cols-[28rem_1fr] items-start gap-8">
        <nav aria-label="Memory files">
          <Tree list={data} selected={selected} />
          {data.outside_layout.length > 0 && (
            <p className="px-3 text-xs text-stone-500">
              Not in the layout: <span className="font-mono">{data.outside_layout.join(', ')}</span>
            </p>
          )}
          {data.files.length === 0 && <p className="px-3 text-sm text-stone-500">The store holds no rule files yet.</p>}
        </nav>
        <div className="sticky top-6 max-h-[calc(100vh-3rem)] overflow-y-auto pb-6 pr-1">
          {missing ? <MissingFile path={missing} /> : selected ? <FileView key={selected} path={selected} known={known} /> : null}
        </div>
      </div>
    </div>
  )
}
