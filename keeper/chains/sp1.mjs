// Runs one of the repo's SP1 hosts (`proofs/<chain>/target/release/<host> prove ...`) on the prover network and reads
// its output: `{ publicValues, proof }`. DRAFT, untested (2026-10-06). Proving costs money on the network
// (NETWORK_PRIVATE_KEY) or needs a GPU (SP1_PROVER=cuda); the hosts refuse the CPU.
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const ROOT = resolve(fileURLToPath(import.meta.url), "../../..");

export function workdir(name) {
  return mkdtempSync(join(tmpdir(), `xindex-${name}-`));
}

/// Runs `cmd args` in `cwd`, inheriting the environment plus `env`, and returns its stdout.
export function run(cmd, args, cwd, env = {}) {
  return execFileSync(cmd, args, { cwd, env: { ...process.env, ...env }, encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] });
}

/// `proofs/<crate>/target/release/<host> prove <...args> <out>`, on SP1_PROVER (network unless set).
export function prove(crate, host, args) {
  const dir = workdir(host);
  const out = join(dir, "proof.json");
  run(join(ROOT, "proofs", crate, "target", "release", host), ["prove", ...args, out], join(ROOT, "proofs", crate), {
    SP1_PROVER: process.env.SP1_PROVER ?? "network",
  });
  const result = JSON.parse(readFileSync(out, "utf8"));
  return { publicValues: result.publicValues, proof: result.proof };
}

export function writeJson(dir, name, value) {
  const path = join(dir, name);
  writeFileSync(path, JSON.stringify(value, (_, v) => (typeof v === "bigint" ? v.toString() : v), 1));
  return path;
}
