import {
  forceCenter,
  forceCollide,
  forceLink,
  forceManyBody,
  forceX,
  forceY,
  forceSimulation,
  type Simulation,
  type SimulationLinkDatum,
  type SimulationNodeDatum,
} from 'd3-force'
import { useCallback, useEffect, useLayoutEffect, useMemo, useReducer, useRef, useState, type PointerEvent as ReactPointerEvent, type ReactNode } from 'react'
import { ErrorBox, Loading, PageHeader } from '../components'
import { basename, plural } from '../format'
import { Icon } from '../icons'
import { href, navigate } from '../route'
import type { Graph as GraphData, GraphNode } from '../types'
import { useApi } from '../useApi'

// One fixed palette; a top-level folder takes the next colour in the order the API lists them.
export const PALETTE = ['#64c8ff', '#a78bfa', '#34d399', '#fbbf24', '#f87171', '#f472b6', '#2dd4bf', '#a3e635']
const ORPHAN = '#ef4444'
const ALL_LABELS_UP_TO = 60
const MIN_ZOOM = 0.25
const MAX_ZOOM = 4
const TICKS = 400

const radiusOf = (degree: number) => 5 + Math.sqrt(degree) * 3.5

interface Sim extends SimulationNodeDatum {
  node: GraphNode
  degree: number
  r: number
  color: string
}

interface Layout {
  sim: Simulation<Sim, SimulationLinkDatum<Sim>>
  nodes: Sim[]
  links: { a: Sim; b: Sim }[]
  folders: { folder: string; color: string; files: number }[]
  maxHeat: number
}

/** A fixed number of ticks, run before the first paint: the same data always lands in the same places. */
function layout(g: GraphData): Layout {
  const degree = new Map<string, number>()
  for (const e of g.edges) {
    degree.set(e.source, (degree.get(e.source) ?? 0) + 1)
    degree.set(e.target, (degree.get(e.target) ?? 0) + 1)
  }
  const folders: Layout['folders'] = []
  for (const n of g.nodes) {
    const f = folders.find((x) => x.folder === n.folder)
    if (f) f.files += 1
    else folders.push({ folder: n.folder, color: PALETTE[folders.length % PALETTE.length], files: 1 })
  }
  const nodes: Sim[] = g.nodes.map((node) => {
    const d = degree.get(node.id) ?? 0
    return { node, degree: d, r: radiusOf(d), color: folders.find((f) => f.folder === node.folder)!.color }
  })
  const byId = new Set(nodes.map((n) => n.node.id))
  const links: SimulationLinkDatum<Sim>[] = g.edges
    .filter((e) => byId.has(e.source) && byId.has(e.target))
    .map((e) => ({ source: e.source, target: e.target }))
  const sim = forceSimulation<Sim>(nodes)
    .force('link', forceLink<Sim, SimulationLinkDatum<Sim>>(links).id((n) => n.node.id).distance(90).strength(0.6))
    .force('charge', forceManyBody().strength(-220))
    .force('collide', forceCollide<Sim>().radius((n) => n.r + 6))
    .force('center', forceCenter(0, 0))
    // a light pull to the middle, so files with no link stay in view instead of drifting off
    .force('x', forceX<Sim>(0).strength(0.05))
    .force('y', forceY<Sim>(0).strength(0.05))
    .stop()
  for (let i = 0; i < TICKS; i++) sim.tick()
  return {
    sim,
    nodes,
    links: links.map((l) => ({ a: l.source as Sim, b: l.target as Sim })),
    folders,
    maxHeat: Math.max(0, ...g.nodes.map((n) => n.heat)),
  }
}

interface View {
  x: number
  y: number
  k: number
}

const clamp = (k: number) => Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, k))

/** The view that shows every node, centred; the margins leave room for a label and the hint line. */
function fitView(nodes: Sim[], w: number, h: number): View {
  if (nodes.length === 0 || w === 0 || h === 0) return { x: w / 2, y: h / 2, k: 1 }
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity
  for (const n of nodes) {
    x0 = Math.min(x0, (n.x ?? 0) - n.r)
    x1 = Math.max(x1, (n.x ?? 0) + n.r)
    y0 = Math.min(y0, (n.y ?? 0) - n.r)
    y1 = Math.max(y1, (n.y ?? 0) + n.r)
  }
  const mx = 80
  const my = 56
  const k = clamp(Math.min((w - 2 * mx) / Math.max(1, x1 - x0), (h - 2 * my) / Math.max(1, y1 - y0), 1.6))
  return { k, x: w / 2 - ((x0 + x1) / 2) * k, y: h / 2 - ((y0 + y1) / 2) * k - 6 }
}

function Canvas({ g, lay }: { g: GraphData; lay: Layout }) {
  const { sim, nodes, links, maxHeat } = lay
  const [, bump] = useReducer((n: number) => n + 1, 0)
  const [hover, setHover] = useState<string | null>(null)
  const [view, setView] = useState<View>({ x: 0, y: 0, k: 1 })
  const [size, setSize] = useState({ w: 0, h: 0 })
  const box = useRef<HTMLDivElement>(null)
  const svg = useRef<SVGSVGElement>(null)
  const viewRef = useRef(view)
  viewRef.current = view
  const fitted = useRef(false)
  const pan = useRef<{ x: number; y: number; vx: number; vy: number } | null>(null)
  const drag = useRef<{ n: Sim; moved: boolean; x: number; y: number } | null>(null)
  const justDragged = useRef(false)

  // the live simulation only runs while a node is being dragged; a tick redraws
  useEffect(() => {
    sim.on('tick', bump)
    return () => {
      sim.on('tick', null)
      sim.stop()
    }
  }, [sim])

  useLayoutEffect(() => {
    const el = box.current
    if (!el) return
    const read = () => setSize({ w: el.clientWidth, h: el.clientHeight })
    read()
    const ro = new ResizeObserver(read)
    ro.observe(el)
    return () => ro.disconnect()
  }, [])

  useEffect(() => {
    if (size.w > 0 && size.h > 0 && !fitted.current) {
      fitted.current = true
      setView(fitView(nodes, size.w, size.h))
    }
  }, [size, nodes])

  const zoomAt = useCallback((px: number, py: number, factor: number) => {
    setView((v) => {
      const k = clamp(v.k * factor)
      return { k, x: px - (px - v.x) * (k / v.k), y: py - (py - v.y) * (k / v.k) }
    })
  }, [])

  // the wheel listener is not passive, so the page behind does not scroll
  useEffect(() => {
    const el = svg.current
    if (!el) return
    const onWheel = (e: WheelEvent) => {
      e.preventDefault()
      const r = el.getBoundingClientRect()
      zoomAt(e.clientX - r.left, e.clientY - r.top, Math.exp(-e.deltaY * 0.0015))
    }
    el.addEventListener('wheel', onWheel, { passive: false })
    return () => el.removeEventListener('wheel', onWheel)
  }, [zoomAt])

  const near = useMemo(() => {
    const s = new Set<string>()
    if (hover) {
      s.add(hover)
      for (const e of g.edges) {
        if (e.source === hover) s.add(e.target)
        if (e.target === hover) s.add(e.source)
      }
    }
    return s
  }, [hover, g])

  const world = (clientX: number, clientY: number) => {
    const r = svg.current!.getBoundingClientRect()
    const v = viewRef.current
    return { x: (clientX - r.left - v.x) / v.k, y: (clientY - r.top - v.y) / v.k }
  }

  // Any press a node did not claim pans: empty canvas, a label, a halo, an edge. A node handler stops
  // the event, so what reaches the svg is by definition not on a node.
  const onBackgroundDown = (e: ReactPointerEvent<SVGSVGElement>) => {
    if (e.button !== 0) return
    e.currentTarget.setPointerCapture(e.pointerId)
    pan.current = { x: e.clientX, y: e.clientY, vx: view.x, vy: view.y }
  }
  const onBackgroundMove = (e: ReactPointerEvent<SVGSVGElement>) => {
    const p = pan.current
    if (p) setView((v) => ({ ...v, x: p.vx + e.clientX - p.x, y: p.vy + e.clientY - p.y }))
  }
  const onBackgroundUp = () => {
    pan.current = null
  }

  const onNodeDown = (e: ReactPointerEvent<SVGGElement>, n: Sim) => {
    if (e.button !== 0) return
    e.stopPropagation()
    e.currentTarget.setPointerCapture(e.pointerId)
    drag.current = { n, moved: false, x: e.clientX, y: e.clientY }
    justDragged.current = false
  }
  const onNodeMove = (e: ReactPointerEvent<SVGGElement>) => {
    const d = drag.current
    if (!d) return
    if (!d.moved && Math.hypot(e.clientX - d.x, e.clientY - d.y) < 4) return
    if (!d.moved) {
      d.moved = true
      sim.alphaTarget(0.3).restart()
    }
    const p = world(e.clientX, e.clientY)
    d.n.fx = p.x
    d.n.fy = p.y
  }
  const onNodeUp = () => {
    const d = drag.current
    drag.current = null
    if (!d?.moved) return
    justDragged.current = true
    d.n.fx = null
    d.n.fy = null
    sim.alphaTarget(0)
  }

  const showAll = nodes.length <= ALL_LABELS_UP_TO
  const k = view.k

  return (
    <div ref={box} className="absolute inset-0">
      <svg
        ref={svg}
        role="group"
        aria-label="Link graph of memory files"
        className="size-full touch-none select-none"
        style={{ cursor: 'grab' }}
        onPointerDown={onBackgroundDown}
        onPointerMove={onBackgroundMove}
        onPointerUp={onBackgroundUp}
        onPointerCancel={onBackgroundUp}
      >
        <defs>
          <filter id="soft" x="-150%" y="-150%" width="400%" height="400%">
            <feGaussianBlur stdDeviation="5" />
          </filter>
        </defs>
        <rect data-bg="" width="100%" height="100%" fill="transparent" />
        <g data-zoom={k.toFixed(3)} transform={`translate(${view.x} ${view.y}) scale(${k})`}>
          {links.map(({ a, b }) => {
            const lit = hover !== null && (a.node.id === hover || b.node.id === hover)
            return (
              <line
                key={`${a.node.id}>${b.node.id}`}
                data-edge=""
                data-lit={lit ? 'true' : 'false'}
                x1={a.x ?? 0}
                y1={a.y ?? 0}
                x2={b.x ?? 0}
                y2={b.y ?? 0}
                stroke={lit ? 'var(--g-edge-lit)' : 'var(--g-edge)'}
                pointerEvents="none"
                strokeWidth={1.2 / k}
                opacity={hover === null ? 0.7 : lit ? 1 : 0.1}
              />
            )
          })}
          {nodes.map((n) => {
            const { node } = n
            const dim = hover !== null && !near.has(node.id)
            const open = () => {
              if (!justDragged.current) navigate('memory', { path: node.id })
              justDragged.current = false
            }
            const halo = node.heat > 0 && maxHeat > 0 ? 0.12 + 0.55 * (node.heat / maxHeat) : 0
            const ringBase = n.r + 3
            return (
              <g
                key={node.id}
                transform={`translate(${n.x ?? 0} ${n.y ?? 0})`}
                role="link"
                tabIndex={0}
                aria-label={`${node.id}: ${plural(node.rules, 'rule')}, ${node.heat} reads, ${plural(n.degree, 'link')}${node.orphan ? ', orphan' : ''}`}
                data-node={node.id}
                data-folder={node.folder}
                data-orphan={node.orphan ? 'true' : 'false'}
                data-core={node.core ? 'true' : 'false'}
                data-dim={dim ? 'true' : 'false'}
                onClick={open}
                onKeyDown={(e) => {
                  if (e.key === 'Enter' || e.key === ' ') {
                    e.preventDefault()
                    navigate('memory', { path: node.id })
                  }
                }}
                onPointerDown={(e) => onNodeDown(e, n)}
                onPointerMove={onNodeMove}
                onPointerUp={onNodeUp}
                onPointerCancel={onNodeUp}
                onMouseEnter={() => setHover(node.id)}
                onMouseLeave={() => setHover(null)}
                onFocus={() => setHover(node.id)}
                onBlur={() => setHover(null)}
                className="outline-none"
                style={{ cursor: 'pointer' }}
                opacity={dim ? 0.15 : 1}
              >
                <title>{`${node.id}\n${plural(node.rules, 'rule')}, ${node.heat} reads, ${plural(n.degree, 'link')}${node.orphan ? '\norphan: no incoming link and no read_when' : ''}`}</title>
                {hover === node.id && <circle data-glow="" r={n.r + 16} fill={n.color} opacity={0.55} filter="url(#soft)" pointerEvents="none" />}
                {halo > 0 && <circle data-halo="" r={n.r + 8} fill={n.color} opacity={halo} filter="url(#soft)" pointerEvents="none" />}
                {node.core && (
                  <>
                    <circle data-ring="core" r={ringBase} fill="none" stroke="var(--g-core-ring)" strokeWidth={1.5 / k} />
                    <circle data-ring="core" r={ringBase + 3.5} fill="none" stroke="var(--g-core-ring)" strokeWidth={1.5 / k} />
                  </>
                )}
                {node.orphan && <circle data-ring="orphan" r={ringBase + (node.core ? 7 : 0)} fill="none" stroke={ORPHAN} strokeWidth={2 / k} pointerEvents="none" />}
                <circle data-hit="" r={n.r + 8} fill="transparent" />
                <circle data-disc="" r={n.r} fill={n.color} stroke="var(--g-outline)" strokeWidth={1.5} />
                {(showAll || near.has(node.id)) && (
                  <text
                    data-label=""
                    textAnchor="middle"
                    y={n.r + (node.core ? 8 : node.orphan ? 4 : 0) + 4 + 11 / k}
                    fontSize={12 / k}
                    fill="var(--g-label)"
                    stroke="var(--g-bg)"
                    strokeWidth={3 / k}
                    paintOrder="stroke"
                    pointerEvents="none"
                  >
                    {basename(node.id)}
                  </text>
                )}
              </g>
            )
          })}
        </g>
      </svg>

      <p data-hint="" className="pointer-events-none absolute bottom-3 left-3 rounded-md px-2 py-1 text-xs text-stone-500"
        style={{ background: 'var(--g-bg)' }}>
        {plural(nodes.length, 'file')} · {plural(links.length, 'link')} · drag to pan · scroll to zoom · click to open
      </p>
      <div role="group" aria-label="Camera" className="absolute bottom-3 right-3 flex flex-col overflow-hidden rounded-lg border border-stone-300 shadow-sm">
        {(
          [
            ['Zoom in', 'plus', () => zoomAt(size.w / 2, size.h / 2, 1.3)],
            ['Zoom out', 'minus', () => zoomAt(size.w / 2, size.h / 2, 1 / 1.3)],
            ['Reset view', 'fit', () => setView(fitView(nodes, size.w, size.h))],
          ] as const
        ).map(([label, icon, run], i) => (
          <button
            key={label}
            type="button"
            aria-label={label}
            title={label}
            onClick={run}
            className={`grid size-9 place-items-center text-stone-700 hover:text-stone-900 focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-indigo-600 ${i > 0 ? 'border-t border-stone-300' : ''}`}
            style={{ background: 'var(--g-btn)' }}
            onMouseEnter={(e) => (e.currentTarget.style.background = 'var(--g-btn-hover)')}
            onMouseLeave={(e) => (e.currentTarget.style.background = 'var(--g-btn)')}
          >
            <Icon name={icon} className="size-4" />
          </button>
        ))}
      </div>
    </div>
  )
}

function Swatch({ color, ring, halo }: { color: string; ring?: 'core' | 'orphan'; halo?: number }) {
  return (
    <svg viewBox="-12 -12 24 24" className="size-6 shrink-0" aria-hidden="true">
      <defs>
        <filter id="swatch-soft" x="-150%" y="-150%" width="400%" height="400%">
          <feGaussianBlur stdDeviation="2.5" />
        </filter>
      </defs>
      {halo ? <circle r={8} fill={color} opacity={halo} filter="url(#swatch-soft)" /> : null}
      {ring === 'core' && (
        <>
          <circle r={7.5} fill="none" stroke="var(--g-core-ring)" strokeWidth={1.2} />
          <circle r={10} fill="none" stroke="var(--g-core-ring)" strokeWidth={1.2} />
        </>
      )}
      {ring === 'orphan' && <circle r={7.5} fill="none" stroke={ORPHAN} strokeWidth={1.8} />}
      <circle r={4.5} fill={color} stroke="var(--g-outline)" strokeWidth={1} />
    </svg>
  )
}

function Panel({ label, icon, iconClass, title, children }: { label: string; icon?: string; iconClass?: string; title: string; children: ReactNode }) {
  return (
    <section aria-label={label} className="rounded-xl border border-stone-200 bg-white p-4">
      <h2 className="mb-3 flex items-center gap-2 text-sm font-semibold text-stone-900">
        {icon && <Icon name={icon} className={`size-4 ${iconClass ?? ''}`} />}
        {title}
      </h2>
      {children}
    </section>
  )
}

function Legend({ lay }: { lay: Layout }) {
  return (
    <Panel label="Legend" title="Legend">
      <ul aria-label="Folders" className="space-y-1.5 text-sm text-stone-700">
        {lay.folders.map((f) => (
          <li key={f.folder} data-folder={f.folder} data-color={f.color} className="flex items-center gap-2">
            <span className="size-3 shrink-0 rounded-full" style={{ background: f.color }} />
            <span className="min-w-0 flex-1 truncate font-mono text-xs font-medium">{f.folder}</span>
            <span className="text-xs text-stone-500">{plural(f.files, 'file')}</span>
          </li>
        ))}
      </ul>
      <ul aria-label="Marks" className="mt-3 space-y-1.5 border-t border-stone-200 pt-3 text-sm text-stone-700">
        <li className="flex items-center gap-2">
          <Swatch color="#a1a1aa" />
          <span><span className="font-medium">Size</span> <span className="text-stone-500">grows with links in and out</span></span>
        </li>
        <li className="flex items-center gap-2">
          <Swatch color="#a1a1aa" ring="core" />
          <span><span className="font-medium">Core</span> <span className="text-stone-500">double ring</span></span>
        </li>
        <li className="flex items-center gap-2">
          <Swatch color="#a1a1aa" ring="orphan" />
          <span><span className="font-medium">Orphan</span> <span className="text-stone-500">red ring: no link in, no read_when</span></span>
        </li>
        <li className="flex items-center gap-2">
          <span className="flex shrink-0 items-center">
            <Swatch color="#a1a1aa" halo={0.12} />
            <Swatch color="#a1a1aa" halo={0.4} />
            <Swatch color="#a1a1aa" halo={0.67} />
          </span>
          <span><span className="font-medium">Halo</span> <span className="text-stone-500">glows brighter the more a file is read{lay.maxHeat > 0 ? ` (up to ${plural(lay.maxHeat, 'read')})` : ''}</span></span>
        </li>
      </ul>
    </Panel>
  )
}

export default function Graph() {
  const { data, error, loading, reload } = useApi<GraphData>('/api/graph')
  const lay = useMemo(() => (data ? layout(data) : null), [data])
  if (error) return <ErrorBox message={error} onRetry={reload} />
  if (!data || loading || !lay) return <Loading what="graph" />

  const orphans = data.nodes.filter((n) => n.orphan)

  return (
    <div className="flex h-screen flex-col px-8 py-6">
      <PageHeader
        title="Graph"
        subtitle={`${plural(data.nodes.length, 'topic file')}, ${plural(data.edges.length, 'link')}. Click a file to open it in Memory.`}
      />
      {data.nodes.length === 0 ? (
        <p className="mt-6 rounded-xl border border-dashed border-stone-300 p-10 text-center text-sm text-stone-500">No topic files to draw yet.</p>
      ) : (
        <div className="mt-5 flex min-h-0 flex-1 gap-5">
          <div className="relative min-w-0 flex-1 overflow-hidden rounded-2xl border border-stone-200" style={{ background: 'var(--g-bg)' }}>
            <Canvas g={data} lay={lay} />
          </div>
          <div className="w-80 shrink-0 space-y-4 overflow-y-auto pb-1">
            <Legend lay={lay} />
            <Panel label="Orphans" icon="orphan" iconClass="text-rose-600" title={`Orphans (${orphans.length})`}>
              {orphans.length === 0 ? (
                <p className="text-sm text-stone-500">None.</p>
              ) : (
                <ul className="space-y-1 text-sm">
                  {orphans.map((n) => (
                    <li key={n.id}>
                      <a href={href('memory', { path: n.id })} className="break-all font-mono text-indigo-700 hover:underline">
                        {n.id}
                      </a>
                    </li>
                  ))}
                </ul>
              )}
            </Panel>
            <Panel label="Broken links" icon="broken" iconClass="text-amber-600" title={`Broken links (${data.broken.length})`}>
              {data.broken.length === 0 ? (
                <p className="text-sm text-stone-500">None.</p>
              ) : (
                <ul className="space-y-2 text-sm">
                  {data.broken.map((b) => (
                    <li key={`${b.source}>${b.target}`}>
                      <a href={href('memory', { path: b.source })} className="block break-words font-mono text-indigo-700 hover:underline">
                        {b.source}
                      </a>
                      <span className="text-stone-500"> links to </span>
                      <span className="break-words font-mono text-stone-900">{b.target}</span>
                      <span className="text-stone-500"> (missing)</span>
                    </li>
                  ))}
                </ul>
              )}
            </Panel>
          </div>
        </div>
      )}
    </div>
  )
}
