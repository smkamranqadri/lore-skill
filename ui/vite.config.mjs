import { fileURLToPath } from 'node:url'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

// The bundle lands where lore_ui.py serves it from: no source maps, no external URL, and no
// asset inlined as a data: URI (the CSP allows data: for images only).
export default defineConfig({
  plugins: [react(), tailwindcss()],
  build: {
    outDir: fileURLToPath(new URL('../skills/lore/ui/dist', import.meta.url)),
    emptyOutDir: true,
    sourcemap: false,
    assetsInlineLimit: 0,
    cssCodeSplit: false,
    modulePreload: { polyfill: false },
  },
  // `npm run dev`: the page from vite, /api from `npm run mock` (the Host header is rewritten
  // because the mock checks it like the real server does).
  server: {
    host: '127.0.0.1',
    proxy: { '/api': { target: 'http://127.0.0.1:3899', changeOrigin: true } },
  },
})
