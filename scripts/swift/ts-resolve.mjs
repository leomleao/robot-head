/* Lets Node run the TS sources as they are. Node 24 strips the types itself,
   but the sources import each other without extensions (`./rig`, `../types`),
   as a bundler allows; this tries `<spec>.ts` for those. Import it before
   importing any .ts file (dynamically, so it is registered first). */

import { registerHooks } from 'node:module';

registerHooks({
  resolve(spec, ctx, next) {
    const relative = spec.startsWith('./') || spec.startsWith('../');
    if (relative && ctx.parentURL?.endsWith('.ts') && !/\.[cm]?[jt]sx?$/.test(spec)) {
      try {
        return next(`${spec}.ts`, ctx);
      } catch {
        /* not a .ts file: let Node say why */
      }
    }
    return next(spec, ctx);
  },
});
