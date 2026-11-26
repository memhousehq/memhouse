// SPDX-License-Identifier: Apache-2.0
// Runs after `napi build` (see "build" in package.json). `napi build` writes index.js and
// index.d.ts anew each time, so what the repository needs in them and the generator does not
// write is added here, not by hand:
//
// - index.js gets the SPDX header every source file carries (the generator has a header
//   option for the declarations, `napi.dtsHeader`, and none for the loader);
// - the `Lite` class is declared with a private constructor. The addon registers only the
//   `open` factory, so `new Lite()` throws at run time; without the declaration TypeScript
//   would accept it.
//
// Each step leaves a file that already has the change as it is, and fails the build when the
// generated text is no longer what it expects, so that a new generator version is noticed.

import { readFileSync, writeFileSync } from 'node:fs'

const SPDX = '// SPDX-License-Identifier: Apache-2.0\n'

function rewrite(name, change) {
  const url = new URL(`../${name}`, import.meta.url)
  const before = readFileSync(url, 'utf8')
  const after = change(before)
  if (after !== before) writeFileSync(url, after)
}

rewrite('index.js', (text) => (text.startsWith(SPDX) ? text : SPDX + text))

rewrite('index.d.ts', (text) => {
  const opening = 'export declare class Lite {\n'
  const constructor = '  /** Not constructible: open one with `await Lite.open(...)`. */\n  private constructor()\n'
  if (text.includes(opening + constructor)) return text
  if (!text.includes(opening) || /^\s*constructor\(/m.test(text)) {
    throw new Error('postbuild: index.d.ts does not declare `Lite` as expected; update bindings/node/scripts/postbuild.mjs')
  }
  return text.replace(opening, opening + constructor)
})
