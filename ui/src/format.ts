// Dates are cut from the server's ISO strings, never converted, so a page reads the same in any
// time zone.
export const day = (iso: string | null | undefined) => (iso ? iso.slice(0, 10) : '')
export const dayTime = (iso: string) => `${iso.slice(0, 10)} ${iso.slice(11, 16)}`.trim()
export const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`
export const basename = (path: string) => path.replace(/^.*\//, '').replace(/\.md$/, '')
export const lastDate = (dates: string[]) => (dates.length ? [...dates].sort()[dates.length - 1] : '')
