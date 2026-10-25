import { useEffect, useState, type ReactNode } from 'react'
import { api, describeError } from '../api'
import { Badge, Button, ConfirmDialog, ErrorBox, Loading, Notice, PageHeader } from '../components'
import { useApp } from '../context'
import { day } from '../format'
import { Icon } from '../icons'
import { inboxKind } from '../kinds'
import type { AcceptResult, InboxItem, RejectResult } from '../types'
import { useApi } from '../useApi'

type Action = 'accept' | 'reject'

interface Outcome {
  tone: 'ok' | 'warn'
  lines: ReactNode[]
}

const EFFECT: Record<string, Record<Action, string>> = {
  layout: {
    accept: 'The proposed top level becomes the layout, as its own commit.',
    reject: 'The proposal is dropped; the store stays as it is.',
  },
  retire: {
    accept: 'The rule moves to retired/, as its own commit.',
    reject: 'The proposal is dropped and not made again on the same evidence.',
  },
  'hand-edit': {
    accept: 'The hand-written rule is kept as it is, as its own commit.',
    reject: 'The hand-written rule is taken out of its file, as its own commit.',
  },
}

const effect = (kind: string, action: Action) =>
  EFFECT[kind]?.[action] ?? (action === 'accept' ? 'The item is applied as its own commit.' : 'The item is dropped.')

const short = (sha: string | null) => (sha ? sha.slice(0, 7) : null)

// `pushed` is true (pushed), false (a hub is set and the push failed or waits: a warning) or null (no
// hub is set: a plain line, never a warning).
function pushLine(res: { pushed: boolean | null; push: string | null }): ReactNode {
  if (!res.push) return null
  if (res.pushed === false) return <p className="font-medium text-amber-900">Not pushed: {res.push}</p>
  return <p className={res.pushed ? 'text-emerald-800' : 'text-stone-600'}>{res.push}</p>
}

export default function Inbox() {
  const { data, error, reload } = useApi<{ items: InboxItem[] }>('/api/inbox')
  const { refreshSummary } = useApp()
  const [ask, setAsk] = useState<{ item: InboxItem; action: Action } | null>(null)
  const [pending, setPending] = useState(false)
  const [dialogError, setDialogError] = useState<string | null>(null)
  const [outcome, setOutcome] = useState<Outcome | null>(null)

  // the item that was acted on leaves the list, and with it the button that had focus: keep focus on the page
  useEffect(() => {
    if (outcome && (!document.activeElement || document.activeElement === document.body)) document.querySelector<HTMLElement>('main')?.focus()
  }, [data, outcome])

  if (error) return <ErrorBox message={error} onRetry={reload} />
  if (!data) return <Loading what="the inbox" />

  const close = () => {
    setAsk(null)
    setDialogError(null)
  }

  const confirm = async () => {
    if (!ask) return
    const { item, action } = ask
    setPending(true)
    setDialogError(null)
    try {
      if (action === 'accept') {
        const res = await api.post<AcceptResult>('/api/inbox/accept', { id: item.id })
        setOutcome({
          tone: res.pushed === false ? 'warn' : 'ok',
          lines: [
            <p key="a" className="font-medium">
              Accepted {inboxKind(item.kind).label.toLowerCase()} {item.id}
              {res.commit ? <>, commit <span className="font-mono">{short(res.commit)}</span></> : ', nothing to commit'}.
            </p>,
            pushLine(res),
          ],
        })
      } else {
        const res = await api.post<RejectResult>('/api/inbox/reject', { id: item.id })
        setOutcome({
          tone: res.pushed === false ? 'warn' : 'ok',
          lines: [
            <p key="a" className="font-medium">
              Rejected {inboxKind(item.kind).label.toLowerCase()} {item.id}
              {res.commit ? <>, commit <span className="font-mono">{short(res.commit)}</span></> : ', no commit'}.
            </p>,
            pushLine(res),
          ],
        })
      }
      close()
      reload()
      refreshSummary()
    } catch (e) {
      setDialogError(describeError(e))
    } finally {
      setPending(false)
    }
  }

  return (
    <div className="px-8 py-6">
      <PageHeader
        title="Inbox"
        subtitle={data.items.length === 0 ? 'Nothing is waiting for you.' : `${data.items.length} waiting for your decision.`}
      />
      <div className="mt-5 space-y-4">
        {outcome && (
          <Notice tone={outcome.tone} onDismiss={() => setOutcome(null)}>
            {outcome.lines}
          </Notice>
        )}
        {data.items.length === 0 ? (
          <div className="rounded-2xl border border-dashed border-stone-300 p-12 text-center">
            <Icon name="inbox" className="mx-auto size-8 text-stone-400" />
            <p className="mt-3 text-sm text-stone-600">The inbox is empty.</p>
          </div>
        ) : (
          <ul aria-label="Inbox items" className="space-y-3">
            {data.items.map((item) => {
              const k = inboxKind(item.kind)
              return (
                <li key={item.id} data-item={item.id} data-kind={item.kind} className="flex items-start gap-4 rounded-2xl border border-stone-200 bg-white p-5">
                  <span className={`flex size-11 shrink-0 items-center justify-center rounded-xl ${k.disc}`}>
                    <Icon name={k.icon} className="size-6" />
                  </span>
                  <div className="min-w-0 flex-1">
                    <div className="flex items-center gap-2">
                      <Badge className={k.chip}>{k.label}</Badge>
                      <span className="font-mono text-xs text-stone-500">{item.id}</span>
                    </div>
                    <p className="mt-2 break-words text-[15px] font-medium leading-snug text-stone-900">{item.summary}</p>
                    <p className="mt-1.5 text-xs text-stone-600">
                      created {day(item.created)} · from {item.source}
                    </p>
                  </div>
                  <div className="flex shrink-0 gap-2">
                    <Button tone="secondary" onClick={() => setAsk({ item, action: 'reject' })} aria-label={`Reject ${item.id}`}>
                      Reject
                    </Button>
                    <Button tone="primary" onClick={() => setAsk({ item, action: 'accept' })} aria-label={`Accept ${item.id}`}>
                      Accept
                    </Button>
                  </div>
                </li>
              )
            })}
          </ul>
        )}
      </div>
      {ask && (
        <ConfirmDialog
          title={ask.action === 'accept' ? 'Accept this item?' : 'Reject this item?'}
          confirmLabel={ask.action === 'accept' ? 'Accept' : 'Reject'}
          tone={ask.action === 'accept' ? 'primary' : 'danger'}
          pending={pending}
          error={dialogError}
          onConfirm={confirm}
          onCancel={close}
        >
          <div className="rounded-lg bg-stone-50 p-3 ring-1 ring-stone-200">
            <p className="text-xs font-semibold uppercase tracking-wide text-stone-500">
              {inboxKind(ask.item.kind).label} <span className="font-mono normal-case">{ask.item.id}</span>
            </p>
            <p className="mt-1 break-words text-stone-900">{ask.item.summary}</p>
          </div>
          <p>{effect(ask.item.kind, ask.action)}</p>
          <p className="text-stone-500">The change is pushed to the hub when one is set.</p>
        </ConfirmDialog>
      )}
    </div>
  )
}
