// The JSON shapes of the lore ui server (the P4a contract). Nothing here is guessed: a field the
// contract does not give is not read.

export interface Summary {
  store: string
  machine: string
  version: string
  head: string
  hub: { url: string | null; last_push: string | null; push_fails: number }
  counts: { files: number; rules: number; inbox: number }
}

export interface MemoryFile {
  path: string
  title: string
  read_when: string | null
  rules: number
  chars: number
  reads: number
  last_read: string | null
  links: string[]
  core: boolean
  lint: string[]
}

export interface MemoryList {
  top: string[]
  files: MemoryFile[]
  outside_layout: string[]
}

export interface Rule {
  id: string
  text: string
  count: number
  explicit: boolean
  created: string
  dates: string[]
  confidence: number | null
  updated: string | null
  quote: string | null
  hand_edit: string | null
  contradictions: unknown[]
}

export interface FileDetail {
  path: string
  title: string
  read_when: string | null
  links: string[]
  reads: Record<string, number>
  last_read: Record<string, string>
  rules: Rule[]
}

export interface GraphNode {
  id: string
  folder: string
  rules: number
  heat: number
  orphan: boolean
  core: boolean
}

export interface Graph {
  nodes: GraphNode[]
  edges: { source: string; target: string }[]
  broken: { source: string; target: string }[]
}

export interface InboxItem {
  id: string
  kind: string
  created: string
  summary: string
  payload: unknown
  source: string
}

export interface CommitRow {
  sha: string
  short: string
  date: string
  subject: string
  kind: string
  files: string[]
}

export interface Changes {
  commits: CommitRow[]
  next: string | null
}

export interface CommitDetail {
  sha: string
  short: string
  date: string
  subject: string
  body: string
  kind: string
  files: { path: string; status: string }[]
  diff: string
  truncated: boolean
  meta_changed: string[]
}

export interface AcceptResult {
  ok: true
  kind: string
  commit: string | null
  push: string | null
  pushed: boolean | null
}

export interface RejectResult {
  ok: true
  commit: string | null
  push: string | null
  pushed: boolean | null
}
