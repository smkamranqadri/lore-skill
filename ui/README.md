# ui/

Source of the `lore ui` app: React, Vite, TypeScript, Tailwind and d3-force. For contributors only;
nothing in this folder is installed. The built bundle is `skills/lore/ui/dist/` (committed), which
`lore ui` serves.

```bash
nvm use                 # node is pinned in .nvmrc and package.json "engines"
npm ci
npm run build           # type-check, then write ../skills/lore/ui/dist
npm run check-dist      # rebuild into a temp folder; exit 1 naming each file that differs
npx playwright install chromium
npm run test:e2e        # Playwright against the real `lore ui` on a fictional temp store
```

Change anything in `src/`, then `npm run build` and commit `skills/lore/ui/dist/` with it: CI runs
`check-dist` and fails on a stale bundle.

- `src/api.ts` is the only place that talks to the server: the token comes from `#t=` once, lives in
  `sessionStorage` and goes out as `X-Lore-Token` on every call.
- `tests/` builds a fictional store with the real `lore` CLI (a temp `HOME`, no git config, a local
  bare repository as the hub) and starts the real server. `LORE_UI_SERVER=mock npm run test:e2e`
  starts `dev/mock-server.mjs` instead (a fixture-backed stand-in, never in the bundle); the specs
  skip what only the real store can prove.
- `npm run mock` serves the bundle with the mock; `npm run dev` runs Vite with `/api` proxied to it
  (`node dev/mock-server.mjs --port 3899` first).
