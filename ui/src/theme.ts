// Dark is the default; light is the owner's choice, kept in localStorage as a per-viewer
// convenience. Every access is guarded: with storage blocked the app still renders, dark.
export type Theme = 'dark' | 'light'

const KEY = 'lore.theme'

export function readTheme(): Theme {
  try {
    return localStorage.getItem(KEY) === 'light' ? 'light' : 'dark'
  } catch {
    return 'dark'
  }
}

export function applyTheme(theme: Theme) {
  document.documentElement.classList.toggle('dark', theme === 'dark')
  document.documentElement.dataset.theme = theme
}

export function saveTheme(theme: Theme) {
  try {
    localStorage.setItem(KEY, theme)
  } catch {
    // storage is blocked; the choice lasts until the page closes
  }
}
