// Runner for the JS MIRROR harnesses.
//
// web/game.js re-implements rules the Zig server owns — the feast walk, slime
// downgrades, chain reactions, cast placement — because the replay has to show
// the player the same meal the server served.  Two implementations of one rule
// is a standing invitation to drift, so each harness extracts the real
// functions out of game.js by name and asserts them against the mirrored Zig
// behaviour.  Extraction (rather than import) is what lets game.js stay a
// plain browser script with no module system.
//
// These ran for months as loose files in a scratch directory, which is exactly
// how one of them rotted: bite_harness kept asserting against a `batches` /
// `settles` return that a refactor had deleted, and nobody noticed because
// nothing ran it.  They live here, and `zig build test` runs them, so that
// cannot happen quietly again.
//
// Contract for a harness: exit 0 and print a one-line OK on success; print
// "FAIL: ..." and exit non-zero otherwise.  No framework — a harness is a
// script, and the assertion helpers are three lines at the top of each.
import { spawnSync } from "node:child_process";
import { readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";

const dir = fileURLToPath(new URL(".", import.meta.url));
const harnesses = readdirSync(dir)
  .filter((f) => f.endsWith("_harness.mjs"))
  .sort();

if (harnesses.length === 0) {
  console.error("FAIL: no harnesses found in", dir);
  process.exit(1);
}

let failed = 0;
for (const h of harnesses) {
  const res = spawnSync(process.execPath, [dir + h], { encoding: "utf8" });
  const ok = res.status === 0;
  if (!ok) failed++;
  // A passing harness is one line; a failing one gets its whole output, since
  // that output is the only description of what broke.
  const tail = (res.stdout || "").trim().split("\n").pop() ?? "";
  console.log(`${ok ? "ok  " : "FAIL"}  ${h.padEnd(20)} ${ok ? tail : ""}`);
  if (!ok) {
    process.stdout.write(res.stdout ?? "");
    process.stderr.write(res.stderr ?? "");
  }
}

console.log(failed === 0
  ? `\n${harnesses.length} mirror harnesses passed`
  : `\n${failed}/${harnesses.length} mirror harnesses FAILED`);
process.exit(failed === 0 ? 0 : 1);
