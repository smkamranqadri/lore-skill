// The only place that talks to the server. The token comes from the address fragment once, lives in
// sessionStorage (never a URL, a cookie or localStorage) and goes out as a header on every call.

const KEY = 'lore.token'
const FRAGMENT = /^#t=([A-Za-z0-9_-]+)$/

let token: string | null = null
const endedListeners = new Set<() => void>()

export class ApiError extends Error {
  status: number
  code: string
  constructor(status: number, code: string, message: string) {
    super(message)
    this.status = status
    this.code = code
  }
}

/** Read `#t=` once, keep it, and strip the fragment from the address bar. Returns the token. */
export function initToken(): string | null {
  const found = FRAGMENT.exec(location.hash)
  let stored: string | null = null
  try {
    stored = sessionStorage.getItem(KEY)
  } catch {
    stored = null
  }
  token = found ? found[1] : stored
  if (found) {
    try {
      sessionStorage.setItem(KEY, found[1])
    } catch {
      // no sessionStorage: the token stays in memory for this page load
    }
    history.replaceState(null, '', location.pathname + location.search)
  }
  return token
}

export function onSessionEnded(fn: () => void): () => void {
  endedListeners.add(fn)
  return () => {
    endedListeners.delete(fn)
  }
}

async function request<T>(method: 'GET' | 'POST', path: string, body?: unknown): Promise<T> {
  const headers: Record<string, string> = { 'X-Lore-Token': token ?? '' }
  if (body !== undefined) headers['Content-Type'] = 'application/json'
  let res: Response
  try {
    res = await fetch(path, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
      cache: 'no-store',
      credentials: 'omit',
    })
  } catch {
    throw new ApiError(0, 'network', 'lore ui cannot be reached; is `lore ui` still running?')
  }
  let data: { error?: string; code?: string } | null = null
  try {
    data = await res.json()
  } catch {
    data = null
  }
  if (res.status === 401) {
    endedListeners.forEach((fn) => fn())
    throw new ApiError(401, 'unauthorized', 'unauthorized')
  }
  if (!res.ok) {
    throw new ApiError(res.status, data?.code ?? 'internal', data?.error ?? `the server answered ${res.status}`)
  }
  return data as T
}

export const api = {
  get: <T>(path: string) => request<T>('GET', path),
  post: <T>(path: string, body: unknown) => request<T>('POST', path, body),
}

/** What a failed write says to the person. */
export function describeError(e: unknown): string {
  if (e instanceof ApiError) {
    if (e.code === 'busy') return 'lore is busy (a session is ending); try again in a moment'
    return e.message
  }
  return e instanceof Error ? e.message : String(e)
}
