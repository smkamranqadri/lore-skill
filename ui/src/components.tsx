import { useEffect, useRef, type ComponentProps, type KeyboardEvent as ReactKeyboardEvent, type ReactNode } from 'react'
import { createPortal } from 'react-dom'
import { Icon } from './icons'

export function Spinner({ className = 'size-4' }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" fill="none" className={`${className} animate-spin`} role="status" aria-label="Working">
      <circle cx="12" cy="12" r="9" stroke="currentColor" strokeOpacity="0.25" strokeWidth="3" />
      <path d="M21 12a9 9 0 0 0-9-9" stroke="currentColor" strokeWidth="3" strokeLinecap="round" />
    </svg>
  )
}

type Tone = 'primary' | 'secondary' | 'danger'
const TONES: Record<Tone, string> = {
  primary: 'bg-accent text-on-solid hover:bg-accent-hover disabled:bg-accent-off',
  secondary: 'bg-white text-stone-800 ring-1 ring-stone-300 hover:bg-stone-50 disabled:text-stone-400',
  danger: 'bg-danger text-on-solid hover:bg-danger-hover disabled:bg-danger-off',
}

interface ButtonProps extends ComponentProps<'button'> {
  tone?: Tone
  pending?: boolean
}

/** A pending button keeps its width: the label stays in the layout, hidden, and a spinner sits over it. */
export function Button({ tone = 'secondary', pending = false, disabled, children, className = '', ...rest }: ButtonProps) {
  return (
    <button
      type="button"
      {...rest}
      disabled={disabled || pending}
      aria-busy={pending || undefined}
      className={`relative inline-flex items-center justify-center gap-2 rounded-lg px-3.5 py-2 text-sm font-semibold transition-colors disabled:cursor-not-allowed ${TONES[tone]} ${className}`}
    >
      <span className={`inline-flex items-center gap-2 ${pending ? 'opacity-0' : ''}`}>{children}</span>
      {pending && (
        <span className="absolute inset-0 flex items-center justify-center">
          <Spinner />
        </span>
      )}
    </button>
  )
}

export function Badge({ children, className = '', title }: { children: ReactNode; className?: string; title?: string }) {
  return (
    <span
      title={title}
      className={`inline-flex items-center gap-1 rounded-md px-1.5 py-0.5 text-xs font-medium ring-1 ring-inset ${className}`}
    >
      {children}
    </span>
  )
}

export type NoticeTone = 'ok' | 'warn' | 'error'
const NOTICE: Record<NoticeTone, { box: string; icon: string }> = {
  ok: { box: 'border-emerald-200 bg-emerald-50 text-emerald-900', icon: 'check' },
  warn: { box: 'border-amber-300 bg-amber-50 text-amber-900', icon: 'alert' },
  error: { box: 'border-rose-200 bg-rose-50 text-rose-900', icon: 'alert' },
}

export function Notice({
  tone,
  children,
  onDismiss,
  role,
}: {
  tone: NoticeTone
  children: ReactNode
  onDismiss?: () => void
  role?: string
}) {
  const t = NOTICE[tone]
  return (
    <div role={role ?? (tone === 'ok' ? 'status' : 'alert')} className={`flex items-start gap-3 rounded-xl border px-4 py-3 text-sm ${t.box}`}>
      <Icon name={t.icon} className="mt-0.5 size-5 shrink-0" />
      <div className="min-w-0 flex-1 space-y-1">{children}</div>
      {onDismiss && (
        <button type="button" onClick={onDismiss} aria-label="Dismiss" className="rounded p-0.5 opacity-70 hover:opacity-100">
          <Icon name="x" className="size-4" />
        </button>
      )}
    </div>
  )
}

/** The app's own confirm dialog (never window.confirm). It stays open on an error, which it shows. */
export function ConfirmDialog({
  title,
  confirmLabel,
  tone = 'primary',
  pending,
  error,
  onConfirm,
  onCancel,
  children,
}: {
  title: string
  confirmLabel: string
  tone?: Tone
  pending: boolean
  error: string | null
  onConfirm: () => void
  onCancel: () => void
  children: ReactNode
}) {
  const cancelRef = useRef<HTMLButtonElement>(null)
  const boxRef = useRef<HTMLDivElement>(null)

  // Modal for the keyboard: the page behind is inert while the dialog is open (its own copy lives in a
  // portal outside #root), focus starts on Cancel, and goes back to the button that opened it.
  useEffect(() => {
    const opener = document.activeElement instanceof HTMLElement ? document.activeElement : null
    const root = document.getElementById('root')
    if (root) root.inert = true
    cancelRef.current?.focus()
    return () => {
      if (root) root.inert = false
      if (opener && document.contains(opener)) opener.focus()
      else document.querySelector<HTMLElement>('main')?.focus()
    }
  }, [])
  // while a write is pending both buttons are disabled: focus rests on the dialog itself, never the page
  useEffect(() => {
    if (pending) boxRef.current?.focus()
    else if (document.activeElement === document.body || document.activeElement === boxRef.current) cancelRef.current?.focus()
  }, [pending])
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && !pending) onCancel()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [pending, onCancel])

  // Tab and Shift+Tab wrap inside the dialog
  const trap = (e: ReactKeyboardEvent<HTMLDivElement>) => {
    if (e.key !== 'Tab') return
    const items = [...(boxRef.current?.querySelectorAll<HTMLElement>('button:not(:disabled), [href], input:not(:disabled), [tabindex]:not([tabindex="-1"])') ?? [])]
    if (items.length === 0) {
      e.preventDefault()
      return
    }
    const first = items[0]
    const last = items[items.length - 1]
    const at = document.activeElement
    if (e.shiftKey && (at === first || at === boxRef.current || !boxRef.current?.contains(at))) {
      e.preventDefault()
      last.focus()
    } else if (!e.shiftKey && (at === last || at === boxRef.current || !boxRef.current?.contains(at))) {
      e.preventDefault()
      first.focus()
    }
  }

  return createPortal(
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-scrim p-6">
      <div
        ref={boxRef}
        role="dialog"
        aria-modal="true"
        aria-label={title}
        tabIndex={-1}
        onKeyDown={trap}
        className="w-full max-w-lg rounded-2xl bg-white p-6 shadow-2xl ring-1 ring-stone-200 outline-none"
      >
        <h2 className="text-lg font-semibold text-stone-900">{title}</h2>
        <div className="mt-3 space-y-3 text-sm text-stone-700">{children}</div>
        {error && (
          <div className="mt-4">
            <Notice tone="error">
              <p>{error}</p>
            </Notice>
          </div>
        )}
        <div className="mt-6 flex justify-end gap-2">
          <Button ref={cancelRef} onClick={onCancel} disabled={pending} tone="secondary">
            Cancel
          </Button>
          <Button tone={tone} pending={pending} onClick={onConfirm}>
            {confirmLabel}
          </Button>
        </div>
      </div>
    </div>,
    document.body,
  )
}

export function PageHeader({ title, subtitle, children }: { title: string; subtitle?: ReactNode; children?: ReactNode }) {
  return (
    <header className="flex items-end justify-between gap-4 border-b border-stone-200 pb-4">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight text-stone-900">{title}</h1>
        {subtitle && <p className="mt-1 text-sm text-stone-600">{subtitle}</p>}
      </div>
      {children}
    </header>
  )
}

export function Loading({ what }: { what: string }) {
  return (
    <div className="flex items-center gap-2 py-10 text-sm text-stone-600">
      <Spinner className="size-4" /> <span>Loading {what}</span>
    </div>
  )
}

export function ErrorBox({ message, onRetry }: { message: string; onRetry?: () => void }) {
  return (
    <div className="py-6">
      <Notice tone="error">
        <p>{message}</p>
        {onRetry && (
          <button type="button" onClick={onRetry} className="font-semibold underline">
            Try again
          </button>
        )}
      </Notice>
    </div>
  )
}
