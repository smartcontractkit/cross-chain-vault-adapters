// Contract size gate. Reads `forge build --sizes --json` from stdin and fails when a contract
// exceeds EIP-170 (runtime) or EIP-3860 (initcode). The contracts listed in
// size-allowlist.json are exempt from EIP-170 but must keep their exact listed runtime size.
import { readFileSync } from "node:fs";

const EIP170_RUNTIME_LIMIT = 24_576;
const EIP3860_INITCODE_LIMIT = 49_152;

const allowlist = JSON.parse(readFileSync(new URL("./size-allowlist.json", import.meta.url), "utf8"));
delete allowlist._comment;

const input = readFileSync(0, "utf8").trim();
if (!input.startsWith("{")) {
  console.error("check-sizes: expected JSON from `forge build --sizes --json`, got:\n" + input);
  process.exit(1);
}
const sizes = JSON.parse(input);

const failures = [];
for (const [name, { runtime_size: runtime, init_size: init }] of Object.entries(sizes)) {
  if (init > EIP3860_INITCODE_LIMIT) failures.push(`${name}: initcode ${init} B exceeds EIP-3860 (${EIP3860_INITCODE_LIMIT} B)`);
  if (name in allowlist) {
    if (runtime !== allowlist[name]) failures.push(`${name}: runtime ${runtime} B differs from allowlisted ${allowlist[name]} B`);
  } else if (runtime > EIP170_RUNTIME_LIMIT) {
    failures.push(`${name}: runtime ${runtime} B exceeds EIP-170 (${EIP170_RUNTIME_LIMIT} B)`);
  }
}
for (const name of Object.keys(allowlist)) {
  if (!(name in sizes)) failures.push(`${name}: listed in size-allowlist.json but not built`);
}

const rows = Object.entries(sizes)
  .filter(([name]) => !name.includes("("))
  .sort(([, a], [, b]) => b.runtime_size - a.runtime_size)
  .slice(0, 15);
console.log("Largest contracts (runtime / initcode bytes):");
for (const [name, s] of rows) {
  const tag = name in allowlist ? "  [allowlisted: exceeds EIP-170]" : "";
  console.log(`  ${name.padEnd(52)} ${String(s.runtime_size).padStart(6)} / ${String(s.init_size).padStart(6)}${tag}`);
}

if (failures.length > 0) {
  console.error("\nContract size check failed:\n  " + failures.join("\n  "));
  process.exit(1);
}
console.log("\nContract size check passed.");
