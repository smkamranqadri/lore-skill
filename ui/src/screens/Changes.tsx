import { useCallback, useEffect, useState } from 'react'
import { api, describeError } from '../api'
import { Badge, Button, ErrorBox, Loading, PageHeader, Spinner } from '../components'
import { dayTime, plural } from '../format'
import { Icon } from '../icons'
import { commitKind } from '../kinds'
import { href, useRoute } from '../route'
import type { Changes as ChangesPage, CommitDetail, CommitRow } from '../types'
import { useApi } from '../useApi'

const PAGE = 20

const STATUS: Record<string, { label: string; cls: string }> = {
  A: { label: 'added', cls: 'bg-emerald-50 text-emerald-700 ring-emerald-200' },
  M: { label: 'modified', cls: 'bg-sky-50 text-sky-700 ring-sky-200' },
  D: { label: 'deleted', cls: 'bg-rose-50 text-rose-700 ring-rose-200' },
  R: { label: 'renamed', cls: 'bg-violet-50 text-violet-700 ring-violet-200' },
}

function diffLine(line: string): string {
  if (line.startsWith('+++') || line.startsWith('---') || line.startsWith('diff ') || line.startsWith('index ')) return 'bg-stone-100 text-stone-600 font-semibold'
  if (line.startsWith('@@')) return 'bg-sky-50 text-sky-800'
  if (line.startsWith('+')) return 'bg-emerald-50 text-emerald-900'
  if (line.startsWith('-')) return 'bg-rose-50 text-rose-900'
  return 'text-stone-700'
}

function Diff({ text }: { text: string }) {
  if (!text.trim()) return <p className="text-sm text-stone-500">No rule text changed in this commit.</p>
  return (
    <pre aria-label="Diff" className="max-h-[26rem] overflow-auto rounded-xl border border-stone-200 bg-white py-2 font-mono text-xs leading-5">
      {text.split('\n').map((l, i) => (
        <div key={i} className={`whitespace-pre px-3 ${diffLine(l)}`}>
          {l || ' '}
        </div>
      ))}
    </pre>
  )
}

function CommitView({ sha }: { sha: string }) {
  const { data, error, loading, reload } = useApi<CommitDetail>(`/api/commit?sha=${encodeURIComponent(sha)}`)
  if (error) return <ErrorBox message={error} onRetry={reload} />
  if (!data || loading) return <Loading what="the commit" />
  const k = commitKind(data.kind)

  return (
    <article aria-label={`Commit ${data.short}`} className="space-y-5">
      <div className="flex items-start gap-4">
        <span className={`flex size-11 shrink-0 items-center justify-center rounded-xl ${k.disc}`}>
          <Icon name={k.icon} className="size-6" />
        </span>
        <div className="min-w-0 flex-1">
          <h2 className="break-words text-xl font-semibold leading-snug text-stone-900">{data.subject}</h2>
          <p className="mt-1 flex flex-wrap items-center gap-2 text-sm text-stone-600">
            <Badge className={k.chip}>{k.label}</Badge>
            <span className="font-mono">{data.short}</span>
            <span>{dayTime(data.date)}</span>
          </p>
        </div>
      </div>

      {data.body.trim() && <pre className="whitespace-pre-wrap rounded-xl bg-white p-4 font-mono text-xs leading-5 text-stone-700 ring-1 ring-stone-200">{data.body.trim()}</pre>}

      <section aria-label="Files">
        <h3 className="mb-2 text-sm font-semibold uppercase tracking-wide text-stone-600">{plural(data.files.length, 'file')} changed</h3>
        <ul className="divide-y divide-stone-100 rounded-xl border border-stone-200 bg-white">
          {data.files.map((f) => {
            const s = STATUS[f.status] ?? { label: f.status, cls: 'bg-stone-100 text-stone-700 ring-stone-300' }
            return (
              <li key={f.path} className="flex items-center gap-3 px-4 py-2 text-sm">
                <Badge className={s.cls}>{s.label}</Badge>
                <span className="font-mono text-stone-900">{f.path}</span>
              </li>
            )
          })}
        </ul>
        {data.meta_changed.length > 0 && (
          <p className="mt-2 text-xs text-stone-600">
            Metadata also changed: <span className="font-mono">{data.meta_changed.join(', ')}</span>
          </p>
        )}
      </section>

      <section aria-label="Diff">
        <h3 className="mb-2 text-sm font-semibold uppercase tracking-wide text-stone-600">Rule text</h3>
        <Diff text={data.diff} />
        {data.truncated && <p className="mt-2 text-xs font-medium text-amber-800">The diff is cut at 200 KB.</p>}
      </section>

    </article>
  )
}

function Row({ c, selected }: { c: CommitRow; selected: boolean }) {
  const k = commitKind(c.kind)
  return (
    <li>
      <a
        href={href('changes', { sha: c.sha })}
        data-sha={c.sha}
        aria-current={selected ? 'true' : undefined}
        className={`flex gap-3 rounded-lg px-3 py-2.5 ${selected ? 'bg-indigo-50 ring-1 ring-indigo-200' : 'hover:bg-stone-100'}`}
      >
        <span className={`mt-0.5 flex size-8 shrink-0 items-center justify-center rounded-lg ${k.disc}`}>
          <Icon name={k.icon} className="size-4" />
        </span>
        <span className="min-w-0 flex-1">
          <span className="line-clamp-2 break-words text-sm font-semibold leading-snug text-stone-900">{c.subject}</span>
          <span className="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-stone-600">
            <Badge className={k.chip}>{k.label}</Badge>
            <span className="font-mono">{c.short}</span>
            <span>{dayTime(c.date)}</span>
            <span>{plural(c.files.length, 'file')}</span>
          </span>
        </span>
      </a>
    </li>
  )
}

export default function Changes() {
  const { params } = useRoute()
  const first = useApi<ChangesPage>(`/api/changes?limit=${PAGE}`)
  const [more, setMore] = useState<CommitRow[]>([])
  const [next, setNext] = useState<string | null | undefined>(undefined)
  const [loadingMore, setLoadingMore] = useState(false)
  const [moreError, setMoreError] = useState<string | null>(null)

  useEffect(() => {
    // a fresh first page starts the list over
    setMore([])
    setNext(undefined)
  }, [first.data])

  const commits = first.data ? [...first.data.commits, ...more] : []
  const cursor = next === undefined ? (first.data?.next ?? null) : next

  const loadMore = useCallback(async () => {
    if (!cursor) return
    setLoadingMore(true)
    setMoreError(null)
    try {
      const page = await api.get<ChangesPage>(`/api/changes?limit=${PAGE}&before=${encodeURIComponent(cursor)}`)
      setMore((m) => [...m, ...page.commits])
      setNext(page.next)
    } catch (e) {
      setMoreError(describeError(e))
    } finally {
      setLoadingMore(false)
    }
  }, [cursor])

  if (first.error) return <ErrorBox message={first.error} onRetry={first.reload} />
  if (!first.data) return <Loading what="changes" />

  const want = params.get('sha') || null
  const selected = commits.find((c) => c.sha === want)?.sha ?? want ?? commits[0]?.sha ?? null

  return (
    <div className="px-8 py-6">
      <PageHeader title="Changes" subtitle="Every commit in the store, newest first." />
      <div className="mt-5 grid grid-cols-[27rem_1fr] items-start gap-8">
        <nav aria-label="Commits">
          <ul className="space-y-0.5">
            {commits.map((c) => (
              <Row key={c.sha} c={c} selected={c.sha === selected} />
            ))}
          </ul>
          {moreError && <p className="px-3 py-2 text-sm text-rose-700">{moreError}</p>}
          {cursor && (
            <div className="px-3 py-4">
              <Button tone="secondary" pending={loadingMore} onClick={loadMore} className="w-full">
                Load more
              </Button>
            </div>
          )}
          {commits.length === 0 && <p className="px-3 text-sm text-stone-500">The store has no commits.</p>}
        </nav>
        <div className="sticky top-6 max-h-[calc(100vh-3rem)] overflow-y-auto pb-6 pr-1">
          {selected ? <CommitView key={selected} sha={selected} /> : <Spinner />}
        </div>
      </div>
    </div>
  )
}
