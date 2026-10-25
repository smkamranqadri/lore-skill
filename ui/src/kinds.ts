// One icon and one colour per kind, so a list reads at a glance.
export interface KindStyle {
  label: string
  icon: string
  chip: string // the badge classes
  disc: string // the round icon background
}

const UNKNOWN: KindStyle = {
  label: 'Other',
  icon: 'info',
  chip: 'bg-stone-100 text-stone-700 ring-stone-300',
  disc: 'bg-stone-100 text-stone-600',
}

const INBOX: Record<string, KindStyle> = {
  layout: {
    label: 'Layout proposal',
    icon: 'layout',
    chip: 'bg-indigo-50 text-indigo-700 ring-indigo-200',
    disc: 'bg-indigo-100 text-indigo-700',
  },
  retire: {
    label: 'Retire a rule',
    icon: 'archive',
    chip: 'bg-amber-50 text-amber-800 ring-amber-200',
    disc: 'bg-amber-100 text-amber-800',
  },
  'hand-edit': {
    label: 'Hand edit',
    icon: 'pencil',
    chip: 'bg-emerald-50 text-emerald-700 ring-emerald-200',
    disc: 'bg-emerald-100 text-emerald-700',
  },
}

const COMMIT: Record<string, KindStyle> = {
  canon: {
    label: 'Canon',
    icon: 'sparkle',
    chip: 'bg-violet-50 text-violet-700 ring-violet-200',
    disc: 'bg-violet-100 text-violet-700',
  },
  loremaster: {
    label: 'Loremaster',
    icon: 'feather',
    chip: 'bg-sky-50 text-sky-700 ring-sky-200',
    disc: 'bg-sky-100 text-sky-700',
  },
  inbox: {
    label: 'Inbox',
    icon: 'tray',
    chip: 'bg-emerald-50 text-emerald-700 ring-emerald-200',
    disc: 'bg-emerald-100 text-emerald-700',
  },
  revert: {
    label: 'Revert',
    icon: 'undo',
    chip: 'bg-rose-50 text-rose-700 ring-rose-200',
    disc: 'bg-rose-100 text-rose-700',
  },
  hub: {
    label: 'Hub',
    icon: 'cloud',
    chip: 'bg-cyan-50 text-cyan-700 ring-cyan-200',
    disc: 'bg-cyan-100 text-cyan-700',
  },
  owner: {
    label: 'Owner',
    icon: 'user',
    chip: 'bg-stone-100 text-stone-700 ring-stone-300',
    disc: 'bg-stone-200 text-stone-700',
  },
}

export const inboxKind = (kind: string): KindStyle => INBOX[kind] ?? { ...UNKNOWN, label: kind }
export const commitKind = (kind: string): KindStyle => COMMIT[kind] ?? { ...UNKNOWN, label: kind }
