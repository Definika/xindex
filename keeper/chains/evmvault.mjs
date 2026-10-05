// What every vault chain running `XindexVault` (BNB Chain, Injective's EVM) shares: deposits under an intake, reading
// what was deposited, balances, and the filler's address as a recipient word. DRAFT, untested (2026-10-06).
import { pad } from "viem";
import { abi } from "../artifacts.mjs";

const ZERO = "0x0000000000000000000000000000000000000000";

export function evmVaultOps(client, wallet) {
  async function send(address, contract, functionName, args, value) {
    const hash = await wallet.writeContract({ address, abi: abi(contract), functionName, args, value, chain: wallet.chain, account: wallet.account });
    const receipt = await client.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") throw new Error(`${functionName} reverted: ${hash}`);
    return receipt;
  }

  return {
    send,

    /// Deposits `amount` of `token` (the zero address for the native coin) into `vault` under `intakeId` for `index`.
    async deposit(vault, index, intakeId, token, amount) {
      if (token === ZERO) return send(vault, "XindexVault", "deposit", [index, intakeId], amount);
      await send(token, "IERC20", "approve", [vault, amount]);
      return send(vault, "XindexVault", "depositToken", [index, intakeId, token, amount]);
    },

    async readDeposited(vault, index, intakeId, token, depositor) {
      return client.readContract({ address: vault, abi: abi("XindexVault"), functionName: "deposited", args: [index, intakeId, token, depositor] });
    },

    async holds(token) {
      if (token === ZERO) return client.getBalance({ address: wallet.account.address });
      return client.readContract({ address: token, abi: abi("IERC20"), functionName: "balanceOf", args: [wallet.account.address] });
    },

    /// The vault's tokens and totals for an intake, the `tokens` and `totals` of a `ChainProof`.
    async intakeTotals(vault, index, intakeId) {
      const tokens = await client.readContract({ address: vault, abi: abi("XindexVault"), functionName: "intakeTokens", args: [index, intakeId] });
      const totals = [];
      for (const t of tokens) {
        totals.push(await client.readContract({ address: vault, abi: abi("XindexVault"), functionName: "intakeTotal", args: [index, intakeId, t] }));
      }
      return { tokens, totals };
    },

    recipient() {
      return pad(wallet.account.address, { size: 32 });
    },
  };
}

/// The vault's slot holding (index, intakeId)'s digest, as the hub reads it: mapping at slot 15 of `index`, then the
/// intake id (`HybridHubStorage.VAULT_INTAKE_DIGEST_SLOT`).
export { intakeSlot } from "./slots.mjs";
