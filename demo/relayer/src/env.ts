// TESTNETS ONLY: the relayer's settings, keys and the deployments the Foundry scripts wrote.
import "dotenv/config";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Keypair, PublicKey } from "@solana/web3.js";
import { type Address, type Hex } from "viem";

const here = dirname(fileURLToPath(import.meta.url));
export const DEMO = resolve(here, "../..");

export function need(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`set ${name} in demo/relayer/.env (see .env.example)`);
  return v;
}

export const key = (name: string) => need(name) as Hex;

export function keypair(name: string): Keypair {
  const path = need(name).replace(/^~/, homedir());
  return Keypair.fromSecretKey(Uint8Array.from(JSON.parse(readFileSync(path, "utf8"))));
}

export const pubkey = (name: string) => new PublicKey(need(name));

function json(file: string): any {
  return JSON.parse(readFileSync(join(DEMO, "deployments", file), "utf8"));
}

/** What `forge script script/Demo.s.sol` deployed, step by step. */
export const deployments = {
  sepolia: () =>
    json("sepolia.json") as {
      factory: Address;
      template: Address;
      solanaStateVerifier: Address;
      hyperStateVerifier: Address;
      weth: Address;
      solanaVault: Hex;
      solanaChainId: number;
      hyperChainId: number;
    },
  hyperevm: () => json("hyperevm.json") as { p1: Address; p2: Address; vault: Address },
  index: () => json("index.json") as { index: Address; salt: Hex; sol: Address; hype: Address },
};

/** An ABI from the demo's Foundry build (`forge build` in demo/). */
export function abi(contract: string): any {
  return JSON.parse(readFileSync(join(DEMO, "out", `${contract}.sol`, `${contract}.json`), "utf8")).abi;
}
