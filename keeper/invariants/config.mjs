// The invariant checker's settings, read from the environment and checked before anything runs. No dependencies.

import { ADDRESS, CHAINS, envReader } from "../bot/config.mjs";

const URL_PATTERN = /^https?:\/\/\S+$/;

export const DEFAULTS = {
  CHAIN_ID: "1",
  POLL_SECONDS: "60",
  LOG_CHUNK: "10000",
};

/// Parses and checks `env`. Throws one Error naming every problem, so a misconfigured checker never starts.
export function parseInvariantsConfig(env) {
  const { problems, get, required, number } = envReader(env, DEFAULTS);
  const optional = (name, pattern, what) => {
    const value = get(name);
    if (value && !pattern.test(value)) problems.push(`${name} must be ${what}`);
    return value ? value : null;
  };

  const config = {
    rpcUrl: required("RPC_URL", URL_PATTERN, "an http(s) URL"),
    chain: CHAINS[get("CHAIN_ID")] ?? null,
    factory: required("FACTORY", ADDRESS, "an address")?.toLowerCase(),
    // MintRequests and the BasketBuilder, whose escrows are checked when set.
    requests: optional("REQUESTS", ADDRESS, "an address")?.toLowerCase() ?? null,
    builder: optional("BUILDER", ADDRESS, "an address")?.toLowerCase() ?? null,
    // The first block whose logs matter: the builder's escrows are found from its events, which start at its
    // deployment. Unset, the admin notices start at the checker's first block and the builder is not checked.
    fromBlock: get("FROM_BLOCK") ? BigInt(number("FROM_BLOCK", { min: 0, integer: true }) || 0) : null,
    pollSeconds: number("POLL_SECONDS", { integer: true, positive: true }),
    // The widest block range one eth_getLogs asks for; public RPCs cap it.
    logChunk: BigInt(number("LOG_CHUNK", { integer: true, positive: true }) || 1),
    // A Slack or Discord incoming webhook that receives every breach and reader finding when raised and cleared.
    alertWebhook: optional("ALERT_WEBHOOK", URL_PATTERN, "an http(s) URL"),
  };
  if (!config.chain) problems.push(`CHAIN_ID must be one of ${Object.keys(CHAINS).join(", ")}`);
  if (config.builder && config.fromBlock === null) problems.push("BUILDER needs FROM_BLOCK, the builder's deployment block");

  if (problems.length) throw new Error(`invariant checker configuration:\n  ${problems.join("\n  ")}`);
  return Object.freeze(config);
}
