import { useCallback, useEffect, useRef, useState } from 'react'
import { api, describeError } from './api'

export interface Loaded<T> {
  data: T | null
  error: string | null
  loading: boolean
  reload: () => void
}

/** GET `path` (null waits). A newer path or an unmount drops an older answer. */
export function useApi<T>(path: string | null): Loaded<T> {
  const [data, setData] = useState<T | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(path !== null)
  const [tick, setTick] = useState(0)
  const last = useRef<string | null>(null)

  useEffect(() => {
    if (path === null) {
      setLoading(false)
      return
    }
    let live = true
    if (last.current !== path) setData(null)
    last.current = path
    setLoading(true)
    setError(null)
    api
      .get<T>(path)
      .then((d) => {
        if (live) setData(d)
      })
      .catch((e) => {
        if (live) setError(describeError(e))
      })
      .finally(() => {
        if (live) setLoading(false)
      })
    return () => {
      live = false
    }
  }, [path, tick])

  const reload = useCallback(() => setTick((n) => n + 1), [])
  return { data, error, loading, reload }
}
