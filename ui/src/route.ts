import { useEffect, useState } from 'react'

export type Screen = 'memory' | 'graph' | 'inbox' | 'changes'
export const SCREENS: Screen[] = ['memory', 'graph', 'inbox', 'changes']

export interface Route {
  screen: Screen
  params: URLSearchParams
}

function parse(): Route {
  const raw = location.hash.replace(/^#\/?/, '')
  const [name = '', query = ''] = raw.split('?')
  const screen = (SCREENS as string[]).includes(name) ? (name as Screen) : 'memory'
  return { screen, params: new URLSearchParams(query) }
}

export function href(screen: Screen, params?: Record<string, string>): string {
  const q = params ? new URLSearchParams(params).toString() : ''
  return `#/${screen}${q ? `?${q}` : ''}`
}

export function navigate(screen: Screen, params?: Record<string, string>) {
  location.hash = href(screen, params)
}

export function useRoute(): Route {
  const [route, setRoute] = useState<Route>(parse)
  useEffect(() => {
    const on = () => setRoute(parse())
    window.addEventListener('hashchange', on)
    return () => window.removeEventListener('hashchange', on)
  }, [])
  return route
}
