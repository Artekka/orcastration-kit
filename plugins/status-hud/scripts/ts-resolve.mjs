// Lets plain node (22.18+) run the HUD's TypeScript scripts: the sources import '../lib/x' without the .ts
// the engine's loader adds. Used by scripts/hud-guide.sh build: node --import ./ts-resolve.mjs guide.ts
import { registerHooks } from 'node:module'
registerHooks({
  resolve(spec, ctx, next) {
    try { return next(spec, ctx) } catch (e) { if (spec.startsWith('.')) return next(`${spec}.ts`, ctx); throw e }
  },
})
