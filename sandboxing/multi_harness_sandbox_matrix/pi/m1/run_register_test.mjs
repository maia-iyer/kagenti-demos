/**
 * Loader shim for register_test.mjs.
 *
 * The registration test has to import the extension, and the extension
 * imports Pi's package. Pi loads extensions with jiti, which resolves the
 * globally-installed package correctly; tsx's resolver does not (it rejects
 * the package's exports map). Rather than test under a resolver Pi does not
 * use, this shim borrows the jiti that ships inside Pi itself — the same code
 * path a real `pi -e ...` invocation takes.
 *
 * Run: node pi/m1/run_register_test.mjs
 */

import { existsSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));

// Locate Pi's install, and the jiti bundled with it.
//
// Note: require.resolve CANNOT be used on Pi's package name. Its exports map
// declares only an "import" condition, so CJS resolution fails with
// 'No "exports" main defined' while ESM import of the same package succeeds.
// That mismatch is also why tsx cannot load the extension and jiti can. We
// therefore locate the package by path rather than by resolution.
const require = createRequire(import.meta.url);
const globalRoots = [
  // npm global root on an nvm-managed install, plus the usual suspects.
  join(dirname(dirname(process.execPath)), "lib", "node_modules"),
  "/usr/local/lib/node_modules",
  "/opt/homebrew/lib/node_modules",
];

let jitiPath;
let piPkgRoot;
for (const root of globalRoots) {
  const pkgRoot = join(root, "@earendil-works", "pi-coding-agent");
  if (!existsSync(join(pkgRoot, "package.json"))) continue;
  try {
    jitiPath = require.resolve("jiti", { paths: [join(pkgRoot, "node_modules")] });
    piPkgRoot = pkgRoot;
    break;
  } catch {
    // Keep looking; a package without its own jiti is not the one we want.
  }
}

if (!jitiPath) {
  console.log("SKIP registration test: could not locate Pi's bundled jiti.");
  console.log(`      Looked in: ${globalRoots.join(", ")}`);
  console.log("      The execution contract is covered by ops_test.mjs.");
  process.exit(0);
}

const { createJiti } = require(jitiPath);
// Alias the bare package name to the install we found. A real `pi -e ...`
// run resolves it from Pi's own directory; this test runs from the project,
// which has no node_modules, so the alias stands in for that.
const jiti = createJiti(`${HERE}/`, {
  interopDefault: true,
  alias: { "@earendil-works/pi-coding-agent": join(piPkgRoot, "dist", "index.js") },
});

// register_test.mjs reads its subject from globalThis so this shim controls
// how the extension gets loaded.
globalThis.__loadExtension = () => jiti.import("./index.ts", { default: true });

await import("./register_test.mjs");
