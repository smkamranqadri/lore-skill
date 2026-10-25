import { useCallback, useEffect, useState } from 'react'
import { api, initToken, onSessionEnded } from './api'
import { AppContext } from './context'
import { Icon } from './icons'
import { day, plural } from './format'
import { href, SCREENS, useRoute, type Screen } from './route'
import Changes from './screens/Changes'
import Graph from './screens/Graph'
import Inbox from './screens/Inbox'
import Memory from './screens/Memory'
import { applyTheme, readTheme, saveTheme, type Theme } from './theme'
import type { Summary } from './types'

const NAV: Record<Screen, { label: string; icon: string }> = {
  memory: { label: 'Memory', icon: 'memory' },
  graph: { label: 'Graph', icon: 'graph' },
  inbox: { label: 'Inbox', icon: 'inbox' },
  changes: { label: 'Changes', icon: 'changes' },
}

function SessionEnded() {
  return (
    <main className="flex h-full items-center justify-center p-8">
      <div className="max-w-md rounded-2xl bg-white p-8 text-center shadow-sm ring-1 ring-stone-200">
        <Icon name="alert" className="mx-auto size-8 text-amber-600" />
        <p className="mt-4 text-lg font-semibold leading-snug text-stone-900">
          This session ended. Run <code className="rounded bg-stone-100 px-1.5 py-0.5 font-mono text-base">lore ui</code> again and open the new link.
        </p>
      </div>
    </main>
  )
}

/** A toggle switch, never a checkbox: on means the light theme, off is the dark default. */
function ThemeSwitch() {
  const [theme, setTheme] = useState<Theme>(readTheme)
  const light = theme === 'light'
  const flip = () => {
    const next: Theme = light ? 'dark' : 'light'
    applyTheme(next)
    saveTheme(next)
    setTheme(next)
  }
  return (
    <div className="flex items-center justify-between border-t border-stone-200 px-5 py-3">
      <span id="theme-label" className="flex items-center gap-2 text-xs font-semibold text-stone-600">
        <Icon name={light ? 'sun' : 'moon'} className="size-4" />
        Light theme
      </span>
      <button
        type="button"
        role="switch"
        aria-checked={light}
        aria-labelledby="theme-label"
        onClick={flip}
        className={`relative h-6 w-11 shrink-0 rounded-full transition-colors focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-indigo-600 ${light ? 'bg-accent' : 'bg-stone-300'}`}
      >
        <span className={`absolute left-0.5 top-0.5 size-5 rounded-full bg-[#ffffff] shadow transition-transform ${light ? 'translate-x-5' : ''}`} />
      </button>
    </div>
  )
}

function Sidebar({ summary, screen }: { summary: Summary | null; screen: Screen }) {
  const hub = summary?.hub
  return (
    <div className="w-60 shrink-0 border-r border-stone-200 bg-white">
    <aside className="sticky top-0 flex h-screen flex-col">
      <div className="px-5 pb-4 pt-6">
        <p className="text-2xl font-bold tracking-tight text-stone-900">lore</p>
        <p className="text-xs text-stone-500">{summary ? `version ${summary.version}` : ' '}</p>
      </div>
      <nav aria-label="Screens" className="space-y-1 px-3">
        {SCREENS.map((s) => {
          const on = s === screen
          const inbox = s === 'inbox' ? summary?.counts.inbox : undefined
          return (
            <a
              key={s}
              href={href(s)}
              aria-current={on ? 'page' : undefined}
              className={`flex items-center gap-3 rounded-lg px-3 py-2.5 text-sm font-semibold ${on ? 'bg-indigo-50 text-indigo-700' : 'text-stone-700 hover:bg-stone-100'}`}
            >
              <Icon name={NAV[s].icon} className="size-5" />
              <span className="flex-1">{NAV[s].label}</span>
              {inbox ? <span aria-label={`${inbox} waiting`} className="rounded-full bg-accent px-2 py-0.5 text-xs font-bold text-on-solid">{inbox}</span> : null}
            </a>
          )
        })}
      </nav>
      <dl className="mt-auto space-y-2 border-t border-stone-100 px-5 py-4 text-xs text-stone-600">
        {summary ? (
          <>
            <div>
              <dt className="font-semibold text-stone-500">Store</dt>
              <dd className="break-all font-mono" title={summary.store}>{summary.store}</dd>
            </div>
            <div className="flex gap-4">
              <div>
                <dt className="font-semibold text-stone-500">Head</dt>
                <dd className="font-mono">{summary.head}</dd>
              </div>
              <div>
                <dt className="font-semibold text-stone-500">Machine</dt>
                <dd>{summary.machine}</dd>
              </div>
            </div>
            <div>
              <dt className="font-semibold text-stone-500">Content</dt>
              <dd>{plural(summary.counts.files, 'file')}, {plural(summary.counts.rules, 'rule')}</dd>
            </div>
            <div>
              <dt className="font-semibold text-stone-500">Hub</dt>
              <dd className={hub && hub.push_fails > 0 ? 'font-medium text-amber-800' : ''}>
                {hub?.url ? (
                  <>
                    <span className="break-all font-mono">{hub.url}</span>
                    <br />
                    {hub.last_push ? `last push ${day(hub.last_push)}` : 'not pushed yet'}
                    {hub.push_fails > 0 ? `; ${plural(hub.push_fails, 'push')} failed` : ''}
                  </>
                ) : (
                  'none (local git only)'
                )}
              </dd>
            </div>
          </>
        ) : (
          <p>Loading</p>
        )}
      </dl>
      <ThemeSwitch />
    </aside>
    </div>
  )
}

export default function App() {
  const [token] = useState(initToken)
  const [ended, setEnded] = useState(token === null)
  const [summary, setSummary] = useState<Summary | null>(null)
  const { screen } = useRoute()

  useEffect(() => onSessionEnded(() => setEnded(true)), [])

  const refreshSummary = useCallback(() => {
    api.get<Summary>('/api/summary').then(setSummary).catch(() => {})
  }, [])

  useEffect(() => {
    if (!ended) refreshSummary()
  }, [ended, refreshSummary])

  if (ended) return <SessionEnded />

  return (
    <AppContext.Provider value={{ summary, refreshSummary }}>
      <div className="flex min-h-full min-w-[1180px]">
        <Sidebar summary={summary} screen={screen} />
        <main tabIndex={-1} className="min-w-0 flex-1 outline-none">
          {screen === 'memory' && <Memory />}
          {screen === 'graph' && <Graph />}
          {screen === 'inbox' && <Inbox />}
          {screen === 'changes' && <Changes />}
        </main>
      </div>
    </AppContext.Provider>
  )
}
