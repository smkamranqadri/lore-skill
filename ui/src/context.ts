import { createContext, useContext } from 'react'
import type { Summary } from './types'

export interface AppState {
  summary: Summary | null
  refreshSummary: () => void
}

export const AppContext = createContext<AppState>({ summary: null, refreshSummary: () => {} })
export const useApp = () => useContext(AppContext)
