import type { ReactNode } from 'react'

// Hand-drawn 24px stroke icons, so the bundle needs no icon font and no file.
const PATHS: Record<string, ReactNode> = {
  memory: (
    <>
      <path d="M5 4.5A1.5 1.5 0 0 1 6.5 3H19v15H6.5A1.5 1.5 0 0 0 5 19.5z" />
      <path d="M5 19.5A1.5 1.5 0 0 0 6.5 21H19v-3" />
      <path d="M9 7.5h6M9 11h4" />
    </>
  ),
  graph: (
    <>
      <circle cx="6" cy="6.5" r="2.4" />
      <circle cx="18" cy="8" r="2.4" />
      <circle cx="11" cy="18" r="2.4" />
      <path d="M8.2 7.2l7.6.5M7 8.6l3 7.2M16.9 10.2l-4.6 6" />
    </>
  ),
  inbox: (
    <>
      <path d="M3.5 13.5l2.4-7.2A1.5 1.5 0 0 1 7.3 5.3h9.4a1.5 1.5 0 0 1 1.4 1l2.4 7.2" />
      <path d="M3.5 13.5V18a1.5 1.5 0 0 0 1.5 1.5h14a1.5 1.5 0 0 0 1.5-1.5v-4.5h-5l-1.2 2.2h-5.6L8.5 13.5z" />
    </>
  ),
  changes: (
    <>
      <circle cx="12" cy="12" r="8.5" />
      <path d="M12 7.5V12l3 2" />
    </>
  ),
  file: (
    <>
      <path d="M7 3h7l4.5 4.5V20A1 1 0 0 1 17.5 21h-10.5A1 1 0 0 1 6 20V4A1 1 0 0 1 7 3z" />
      <path d="M14 3v4.5h4.5M9 12.5h6M9 16h6" />
    </>
  ),
  core: <path d="M12 3.2l2.7 5.5 6 .9-4.4 4.2 1.1 6-5.4-2.9-5.4 2.9 1.1-6-4.4-4.2 6-.9z" />,
  folder: <path d="M3.5 6.5A1.5 1.5 0 0 1 5 5h4.2l2 2.3H19a1.5 1.5 0 0 1 1.5 1.5v8.7A1.5 1.5 0 0 1 19 19H5a1.5 1.5 0 0 1-1.5-1.5z" />,
  layout: (
    <>
      <rect x="3.5" y="4" width="7" height="6" rx="1.2" />
      <rect x="13.5" y="4" width="7" height="6" rx="1.2" />
      <rect x="3.5" y="14" width="7" height="6" rx="1.2" />
      <path d="M17 13.5v7M13.5 17h7" />
    </>
  ),
  archive: (
    <>
      <rect x="3.5" y="4.5" width="17" height="4.5" rx="1" />
      <path d="M5 9v9.5A1.5 1.5 0 0 0 6.5 20h11a1.5 1.5 0 0 0 1.5-1.5V9M10 13h4" />
    </>
  ),
  pencil: (
    <>
      <path d="M4 20l1-4.2L16.6 4.2a1.8 1.8 0 0 1 2.5 0l.7.7a1.8 1.8 0 0 1 0 2.5L8.2 19z" />
      <path d="M14.5 6.3l3.2 3.2" />
    </>
  ),
  sparkle: (
    <>
      <path d="M10 3.5l1.6 4.9 4.9 1.6-4.9 1.6L10 16.5 8.4 11.6 3.5 10l4.9-1.6z" />
      <path d="M18 14.5l.8 2.2 2.2.8-2.2.8-.8 2.2-.8-2.2-2.2-.8 2.2-.8z" />
    </>
  ),
  feather: (
    <>
      <path d="M20 4c-7 0-12 4-12 10v3.5h3.5c6 0 8.5-5 8.5-13.5z" />
      <path d="M4 20l8-8M14 9.5h-4" />
    </>
  ),
  tray: (
    <>
      <path d="M12 4v9m0 0l-3.5-3.5M12 13l3.5-3.5" />
      <path d="M4 14.5V18a1.5 1.5 0 0 0 1.5 1.5h13A1.5 1.5 0 0 0 20 18v-3.5h-4.5l-1 2h-5l-1-2z" />
    </>
  ),
  undo: (
    <>
      <path d="M9 14L4 9l5-5" />
      <path d="M4 9h10.5a5.5 5.5 0 0 1 0 11H11" />
    </>
  ),
  cloud: <path d="M7 18.5a4.5 4.5 0 0 1-.6-8.96A6 6 0 0 1 17.9 8.9 4.8 4.8 0 0 1 17.5 18.5z" />,
  user: (
    <>
      <circle cx="12" cy="8" r="3.6" />
      <path d="M4.8 20a7.2 7.2 0 0 1 14.4 0" />
    </>
  ),
  eye: (
    <>
      <path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z" />
      <circle cx="12" cy="12" r="2.8" />
    </>
  ),
  pin: (
    <>
      <path d="M14.5 3.5l6 6-2.4.6-3.2 3.2.2 3.6-1.2 1.2-3.7-3.7L5 20l-1-1 5.6-5.4-3.7-3.7 1.2-1.2 3.6.2 3.2-3.2z" />
    </>
  ),
  link: (
    <>
      <path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1" />
      <path d="M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1" />
    </>
  ),
  alert: (
    <>
      <path d="M12 3.5l9.2 16H2.8z" />
      <path d="M12 10v4.5M12 17.4v.1" />
    </>
  ),
  check: <path d="M4.5 12.5l5 5 10-11" />,
  x: <path d="M6 6l12 12M18 6L6 18" />,
  info: (
    <>
      <circle cx="12" cy="12" r="8.5" />
      <path d="M12 11v5M12 8v.1" />
    </>
  ),
  orphan: (
    <>
      <circle cx="12" cy="12" r="7.5" strokeDasharray="3 3" />
      <circle cx="12" cy="12" r="2" />
    </>
  ),
  sun: (
    <>
      <circle cx="12" cy="12" r="4" />
      <path d="M12 3v2M12 19v2M3 12h2M19 12h2M5.6 5.6L7 7M17 17l1.4 1.4M18.4 5.6L17 7M7 17l-1.4 1.4" />
    </>
  ),
  moon: <path d="M20 14.5A8.5 8.5 0 0 1 9.5 4 8.5 8.5 0 1 0 20 14.5z" />,
  chevron: <path d="M9 6l6 6-6 6" />,
  plus: <path d="M12 5v14M5 12h14" />,
  minus: <path d="M5 12h14" />,
  fit: <path d="M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5" />,
  broken: (
    <>
      <path d="M10 14a4 4 0 0 0 1.5 1M14.5 9.5L16 8a4 4 0 0 0-5.7-5.7l-1 1" />
      <path d="M8 12l-3 3a4 4 0 0 0 5.7 5.7l1-1M4 4l16 16" />
    </>
  ),
}

export type IconName = keyof typeof PATHS

export function Icon({ name, className = 'size-5' }: { name: IconName | string; className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.8}
      strokeLinecap="round"
      strokeLinejoin="round"
      className={className}
      aria-hidden="true"
    >
      {PATHS[name] ?? PATHS.info}
    </svg>
  )
}
