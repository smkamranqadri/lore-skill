// The fictional store the e2e suite runs against, and the single place its expected values come
// from. global-setup.mjs builds a real lore store from it (real `lore` CLI, a local bare hub);
// dev/mock-server.mjs derives the contract's JSON from it. Every name, rule and path is invented.
//
// Dates are written as "days before the anchor" so the stale and thin lint gates never fire on a
// fixture that ages; the anchor is the day the run starts and travels in LORE_E2E_TODAY.

import { createHash } from 'node:crypto'

export const anchor = () => process.env.LORE_E2E_TODAY ?? new Date().toISOString().slice(0, 10)
export const ago = (n) => {
  const d = new Date(`${anchor()}T00:00:00Z`)
  d.setUTCDate(d.getUTCDate() - n)
  return d.toISOString().slice(0, 10)
}
export const ruleId = (text) => createHash('sha1').update(text).digest('hex').slice(0, 8)

export const TOP = ['profile.md', 'how-i-work/', 'preferences/', 'safety/', 'stack/', 'gotchas/']
export const MACHINES = ['fern-desktop', 'pine-laptop']

const r = (text, o = {}) => ({ text, count: 1, explicit: false, createdAgo: 20, datesAgo: [20], ...o })

// Seed files, as the first commit writes them.
export const SEED = [
  {
    path: 'core.md', title: 'Core', readWhen: null, links: [],
    reads: { 'fern-desktop': 12, 'pine-laptop': 5 }, lastReadAgo: { 'fern-desktop': 2, 'pine-laptop': 4 },
    rules: [
      r('State the plan in two sentences before touching any file.', { count: 6, explicit: true, datesAgo: [20, 11, 3] }),
      r('Never print a token, password or key; refer to it by name.', { count: 4, explicit: true, datesAgo: [20, 6] }),
      r('Run the real command before saying a task is done.', { count: 3, datesAgo: [20, 9, 2] }),
    ],
  },
  {
    path: 'profile.md', title: 'Profile', readWhen: 'you need to know who the user is', links: [],
    reads: { 'fern-desktop': 4 }, lastReadAgo: { 'fern-desktop': 5 },
    rules: [
      r('Works alone on small web tools for a harbour ferry cooperative.', { explicit: true }),
      r('Wants short answers with the verdict first.', { count: 2, datesAgo: [20, 8] }),
    ],
  },
  {
    path: 'how-i-work/planning.md', title: 'Planning', readWhen: 'planning or scoping a task',
    links: ['how-i-work/reviews.md', 'preferences/editor.md'],
    reads: { 'fern-desktop': 6, 'pine-laptop': 3 }, lastReadAgo: { 'fern-desktop': 1, 'pine-laptop': 7 },
    rules: [
      r('Split work into steps that each end in a command that can be run.', { count: 5, explicit: true, datesAgo: [20, 14, 7, 2] }),
      r('Write down what is out of scope before starting.', { count: 2, datesAgo: [18, 5] }),
      r('Ask all missing requirements in one message, not one at a time.', { count: 3, explicit: true, createdAgo: 17, datesAgo: [17, 10, 1] }),
      r('Prefer the smallest change that satisfies the request.', { count: 2, createdAgo: 15, datesAgo: [15, 4] }),
    ],
  },
  {
    path: 'how-i-work/reviews.md', title: 'Reviews', readWhen: 'reviewing a change or a pull request',
    links: ['safety/backups.md'],
    reads: { 'fern-desktop': 6 }, lastReadAgo: { 'fern-desktop': 3 },
    rules: [
      r('Read the whole diff, including generated files, before approving.', { count: 2, datesAgo: [19, 6] }),
      r('Flag leftover debug output and TODO comments in every review.', { count: 3, createdAgo: 16, datesAgo: [16, 9, 3] }),
      r('Name the file and line for every finding.', { createdAgo: 12, datesAgo: [12] }),
    ],
  },
  {
    path: 'preferences/editor.md', title: 'Editor', readWhen: 'setting up or configuring an editor', links: [],
    reads: {}, lastReadAgo: {},
    rules: [
      r('Use two spaces for indentation in web files.', { explicit: true }),
      r('Keep lines under one hundred characters.', { createdAgo: 14, datesAgo: [14] }),
    ],
  },
  {
    path: 'safety/backups.md', title: 'Backups', readWhen: 'touching backups, deletion or servers',
    links: ['gotchas/quillfeather.md'],
    reads: { 'fern-desktop': 4, 'pine-laptop': 3 }, lastReadAgo: { 'fern-desktop': 8, 'pine-laptop': 12 },
    rules: [
      r('Look at what a directory holds before deleting it.', { count: 4, explicit: true, datesAgo: [20, 13, 5] }),
      r('Take a copy of a database before any migration.', { count: 2, createdAgo: 18, datesAgo: [18, 6] }),
      r('Ask before any write to production, even to fix an outage.', { count: 3, explicit: true, createdAgo: 19, datesAgo: [19, 10, 1] }),
    ],
  },
  {
    path: 'gotchas/brindle-api.md', title: 'Brindle API', readWhen: 'calling the Brindle API', links: [],
    reads: { 'pine-laptop': 2 }, lastReadAgo: { 'pine-laptop': 6 },
    rules: [
      r('The Brindle API answers 200 with an error body on a bad token; read the body.', { createdAgo: 13, datesAgo: [13] }),
      r('Brindle page numbers start at zero.', { createdAgo: 11, datesAgo: [11] }),
    ],
  },
  {
    path: 'gotchas/legacy/ferry-radio.md', title: 'Ferry radio', readWhen: 'using the old ferry radio protocol', links: [],
    reads: { 'pine-laptop': 3 }, lastReadAgo: { 'pine-laptop': 10 },
    rules: [
      r('The old radio protocol sends the vessel code in capitals only.', { createdAgo: 12, datesAgo: [12] }),
      r('Radio time stamps are local time, not UTC.', { count: 2, createdAgo: 14, datesAgo: [14, 5] }),
    ],
  },
  {
    path: 'gotchas/orphaned-tips.md', title: 'Loose tips', readWhen: null, links: [],
    reads: {}, lastReadAgo: {},
    rules: [
      r('Keep a spare charger in the travel bag.', { createdAgo: 9, datesAgo: [9] }),
      r('Label every cable with its length.', { createdAgo: 9, datesAgo: [9] }),
    ],
    expectLint: ['orphan'],
  },
  {
    path: 'gotchas/quillfeather.md', title: 'Quillfeather importer', readWhen: 'using the Quillfeather importer',
    links: ['gotchas/brindle-api.md', 'gotchas/missing-notes.md'],
    reads: { 'fern-desktop': 9, 'pine-laptop': 6 }, lastReadAgo: { 'fern-desktop': 1, 'pine-laptop': 2 },
    rules: [
      r('The Quillfeather importer drops rows with an empty id; count rows before and after.', { count: 3, explicit: true, datesAgo: [20, 10, 4] }),
      r('Quillfeather exports use semicolons in the Nordic locale.', { createdAgo: 16, datesAgo: [16] }),
      r('Run the importer with --dry-run first; it writes to the live tables otherwise.', { count: 2, explicit: true, createdAgo: 15, datesAgo: [15, 3] }),
      r('Large Quillfeather files time out after sixty seconds; split them by month.', { createdAgo: 10, datesAgo: [10] }),
    ],
    expectLint: ['broken-link'],
  },
]

// Fifteen rules that arrive one commit each; they make the Changes list long enough to page.
export const HARBOUR = [
  'Store timetable times in UTC and convert only when displaying them.',
  'Tide tables come as PDF from the port authority; parse them once and cache the result.',
  'Keep passenger counts as integers, never floats.',
  'The booking form must work without JavaScript for the kiosk browser.',
  'Use the three-letter port codes as keys, not display names.',
  'Round fares to whole cents only at the final total.',
  'Kiosk screens stay on for twelve hours, so avoid timers that leak memory.',
  'Cancellation emails go out from the shared mailbox, not a personal one.',
  'Log every crossing delay with its reason code.',
  'Lifejacket counts per vessel live in a spreadsheet owned by the harbourmaster.',
  'Test date handling around the clock change in March and October.',
  'Never delete a booking; mark it cancelled instead.',
  'Wheelchair spaces stay reserved until one hour before departure.',
  'Fog alerts are manual; the app never sends one on its own.',
  'Show kroner amounts with a thin space for thousands.',
]

export const HARBOUR_FILE = {
  path: 'stack/harbour-tools.md', title: 'Harbour tools', readWhen: 'working on the ferry timetable tools', links: [],
  reads: { 'fern-desktop': 2 }, lastReadAgo: { 'fern-desktop': 9 },
}

export const R1 = 'Check that every changed file is named in the pull request text.'
export const R1_REWORDED = 'Check that every changed file is named in the pull request description.'
export const QUILL_CACHE = 'Quillfeather exports are cached for five minutes; add a cache-busting query when testing.'
export const HAND_A = { file: 'gotchas/brindle-api.md', text: 'Brindle rate limits reset at midnight UTC, not on a rolling window.' }
export const HAND_B = { file: 'preferences/editor.md', text: 'Always use tabs in Makefiles, whatever the editor says.' }
export const RETIRE = { file: 'safety/backups.md', text: 'Take a copy of a database before any migration.', reason: 'a stricter rule says it better' }
export const LAYOUT_PROPOSAL = [...TOP, 'tools/']

// The commits after the seed, oldest first. A filing subject is `loremaster <12 hex>: <what changed>`, as lore writes it. `kind` is what /api/changes calls it by subject prefix.
export const HISTORY = [
  { subject: 'loremaster 5e0000000001: file 1 rule in how-i-work/reviews.md', kind: 'loremaster', file: 'how-i-work/reviews.md', add: R1, createdAgo: 8 },
  { subject: 'canon: reword a rule in how-i-work/reviews.md', kind: 'canon', file: 'how-i-work/reviews.md', reword: [R1, R1_REWORDED] },
  { subject: 'loremaster 5e0000000002: file 1 rule in gotchas/quillfeather.md', kind: 'loremaster', file: 'gotchas/quillfeather.md', add: QUILL_CACHE, createdAgo: 6 },
  ...HARBOUR.map((text, i) => ({
    subject: `loremaster b0b0b0b0b0${String(i + 1).padStart(2, '0')}: file 1 rule in stack/harbour-tools.md`,
    kind: 'loremaster', file: 'stack/harbour-tools.md', add: text, createdAgo: 15 - i,
  })),
]
export const SEED_SUBJECT = 'owner: seed the fictional store'
export const HAND_SUBJECTS = [
  `owner: add a rule to ${HAND_A.file}`,
  `owner: add a rule to ${HAND_B.file}`,
]
export const INIT_SUBJECT = 'new lore store'

export function entry(rule, id = ruleId(rule.text)) {
  return [id, {
    text: rule.text, created: ago(rule.createdAgo), explicit: rule.explicit, count: rule.count,
    dates: rule.datesAgo.map(ago).sort(), confidence: rule.explicit ? 0.9 : 0.7, sessions: [],
    updated: `${ago(rule.createdAgo)}T09:00:00+00:00`,
  }]
}

/** The final state of every rule file once the seed, HISTORY and the two hand edits are in. */
export function finalFiles() {
  const files = SEED.map((f) => ({ ...f, rules: f.rules.map((x) => ({ ...x })), hand: [] }))
  files.push({ ...HARBOUR_FILE, rules: [], hand: [], expectLint: [] })
  const byPath = new Map(files.map((f) => [f.path, f]))
  for (const h of HISTORY) {
    const f = byPath.get(h.file)
    if (h.add) f.rules.push(r(h.add, { createdAgo: h.createdAgo ?? 1, datesAgo: [h.createdAgo ?? 1] }))
    if (h.reword) f.rules.find((x) => x.text === h.reword[0]).text = h.reword[1]
  }
  for (const h of [HAND_A, HAND_B]) {
    byPath.get(h.file).rules.push(r(h.text, { explicit: true, createdAgo: 0, datesAgo: [0] }))
    byPath.get(h.file).hand.push(h.text)
  }
  const rank = (p) => (p === 'core.md' ? -1 : TOP.findIndex((t) => (t.endsWith('/') ? p.startsWith(t) : p === t)))
  return files.sort((a, b) => rank(a.path) - rank(b.path) || (a.path < b.path ? -1 : 1))
}

export const lastReadOf = (f) => Object.values(f.lastReadAgo).map(ago).sort().pop() ?? null
export const readsOf = (f) => Object.values(f.reads).reduce((n, x) => n + x, 0)
export const lastDateOf = (rule) => rule.datesAgo.map(ago).sort().pop()
