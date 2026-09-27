// The only code in this repo that broadcasts a transaction.
//
// Three float burners a simulation cannot catch, because each one only exists between the moment a
// fill simulates cleanly and the moment it lands:
//
//   1. THE SAME ORDER TWICE. A user double-clicks, or a client retries. Both submissions simulate
//      against the same state and both pass; the second is mined after the first and reverts
//      AlreadyExecuted - having paid for the gas. -> one in-flight lock per order hash.
//
//   2. TWO ORDERS FROM ONE OWNER. Each simulates against the balance the other is about to spend,
//      or against the permit nonce the other is about to consume. Both pass, one reverts on-chain.
//      -> one in-flight order per owner.
//
//   3. TWO SENDS FROM ONE KEY. Two fills fetch the same pending nonce; one replaces the other or is
//      rejected, and a stuck low-fee transaction blocks every fill behind it.
//      -> every send goes through one serial queue, nonces are assigned locally, a transaction not
//         mined in time is replaced at the same nonce with a higher fee, and the fill is
//         re-simulated INSIDE the queue - immediately before it is signed - so state that changed
//         while it waited is caught before it costs anything.
//
// The key: on mainnet, read from a 0600 file generated on the VPS. In tests, anvil's well-known
// development key - which this module refuses to use against anything but a local anvil.

import { privateKeyToAccount } from "viem/accounts";
import { call } from "./rpc.mjs";

/** anvil's default accounts. Public knowledge; they must never sign for a real chain. */
export const ANVIL_DEV_ADDRESSES = new Set([
  "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266",
  "0x70997970c51812dc3a010c7d01b50e0d17dc79c8",
  "0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc",
  "0x90f79bf6eb2c4f870365e785982e1f101e93b906",
]);

/**
 * Refuses unless the endpoint is an anvil on this machine. Two independent facts, because a local
 * port can be a tunnel to somewhere real: the URL host is loopback, and the node says it is anvil.
 */
export async function assertLocalAnvil(rpcUrl) {
  const host = new URL(rpcUrl).hostname;
  if (!["127.0.0.1", "localhost", "::1", "[::1]"].includes(host)) {
    throw new Error(`refusing: ${host} is not loopback - the test key only signs for a local anvil`);
  }
  const version = await call("web3_clientVersion", []);
  if (!/^anvil\//i.test(String(version))) {
    throw new Error(`refusing: the node at ${host} reports "${version}", not anvil`);
  }
  return version;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const hexToBig = (h) => BigInt(h);

/**
 * @param {object} o
 * @param {string} o.privateKey   hex key - read by the caller from its file, never logged here
 * @param {number} o.chainId
 * @param {boolean} [o.anvil]     true only after assertLocalAnvil passed
 * @param {number} [o.receiptTimeoutMs]  how long before a replacement is sent
 * @param {number} [o.maxReplacements]
 */
export function createSender({ privateKey, chainId, anvil = false, receiptTimeoutMs = 20_000, maxReplacements = 3 }) {
  const account = privateKeyToAccount(privateKey);
  const addr = account.address.toLowerCase();
  if (ANVIL_DEV_ADDRESSES.has(addr) && !anvil) {
    throw new Error("refusing: an anvil development key was handed to a non-anvil sender");
  }

  let nextNonce = null;
  let tail = Promise.resolve();
  const stats = { sent: 0, replaced: 0, reverted: 0, failed: 0 };

  /** Serialize: every job runs after the previous one has fully settled. */
  function enqueue(job) {
    const run = tail.then(job, job);
    tail = run.catch(() => {});
    return run;
  }

  async function fees(bump = 0) {
    const gp = hexToBig(await call("eth_gasPrice", []));
    // Arbitrum-style sequencer: the priority fee buys nothing, the max fee only has to clear the
    // base fee. Headroom of 2x covers a base-fee move between signing and inclusion; each
    // replacement adds 25%, above the 10% nodes require to accept a same-nonce replacement.
    let maxFeePerGas = gp * 2n;
    for (let i = 0; i < bump; i++) maxFeePerGas = (maxFeePerGas * 125n) / 100n;
    const maxPriorityFeePerGas = bump === 0 ? 0n : (maxFeePerGas / 100n) * BigInt(bump);
    return { maxFeePerGas, maxPriorityFeePerGas };
  }

  async function waitReceipt(hash, timeoutMs) {
    const t0 = Date.now();
    while (Date.now() - t0 < timeoutMs) {
      const r = await call("eth_getTransactionReceipt", [hash]).catch(() => null);
      if (r) return r;
      await sleep(anvil ? 100 : 700);
    }
    return null;
  }

  /**
   * Send one transaction. `resimulate` runs inside the queue, right before signing; if it fails the
   * job is abandoned with nothing broadcast.
   * @returns {{hash:string, receipt:object, gasUsed:bigint, effectiveGasPrice:bigint, replacements:number}}
   */
  function send({ to, data, resimulate = null, label = "" }) {
    return enqueue(async () => {
      if (resimulate) {
        const ok = await resimulate();
        if (!ok.ok) {
          const e = new Error("re-simulation failed inside the send queue - nothing broadcast");
          e.revert = ok.data;
          e.notSent = true;
          throw e;
        }
      }
      if (nextNonce === null) {
        nextNonce = Number(hexToBig(await call("eth_getTransactionCount", [account.address, "pending"])));
      }
      const nonce = nextNonce;

      const estimate = hexToBig(await call("eth_estimateGas", [{ from: account.address, to, data }]));
      const gas = (estimate * 125n) / 100n;

      let hashes = [];
      for (let attempt = 0; attempt <= maxReplacements; attempt++) {
        const f = await fees(attempt);
        const signed = await account.signTransaction({
          type: "eip1559", chainId, nonce, to, data, gas, value: 0n,
          maxFeePerGas: f.maxFeePerGas, maxPriorityFeePerGas: f.maxPriorityFeePerGas,
        });
        let hash;
        try {
          hash = await call("eth_sendRawTransaction", [signed]);
        } catch (e) {
          // "nonce too low" means an earlier attempt at this nonce was mined: look for it.
          if (/nonce too low|already known/i.test(String(e.message)) && hashes.length) {
            for (const h of hashes) {
              const r = await call("eth_getTransactionReceipt", [h]).catch(() => null);
              if (r) return finish(h, r, attempt, nonce, hashes);
            }
          }
          stats.failed++;
          nextNonce = null;          // resync from the chain on the next send
          throw e;
        }
        hashes.push(hash);
        if (attempt > 0) stats.replaced++;
        const r = await waitReceipt(hash, receiptTimeoutMs);
        if (r) return finish(hash, r, attempt, nonce, hashes);
        // not mined in time: an earlier attempt may still land, so check them all before replacing
        for (const h of hashes) {
          const rr = await call("eth_getTransactionReceipt", [h]).catch(() => null);
          if (rr) return finish(h, rr, attempt, nonce, hashes);
        }
      }
      stats.failed++;
      nextNonce = null;
      throw new Error(`nonce ${nonce}: not mined after ${maxReplacements} replacements (${label})`);
    });
  }

  function finish(hash, receipt, replacements, nonce, attempts = [hash]) {
    nextNonce = nonce + 1;
    stats.sent++;
    const ok = receipt.status === "0x1";
    if (!ok) stats.reverted++;
    return {
      hash, receipt, ok, replacements, nonce, attempts: [...attempts],
      gasUsed: hexToBig(receipt.gasUsed),
      effectiveGasPrice: hexToBig(receipt.effectiveGasPrice ?? "0x0"),
    };
  }

  return { address: account.address, send, stats, queueDepth: () => tail };
}

// ---------------------------------------------------------------- in-flight locks

/**
 * One in-flight fill per order hash and per owner. In-process state is enough: there is one
 * relayer process, and the chain's `executed` mapping is the durable record behind it.
 */
export function createLocks() {
  const byOrder = new Map();
  const byOwner = new Map();
  return {
    /** @returns {null | {code:number, reason:string}} */
    acquire(orderHash, owner) {
      const o = String(owner).toLowerCase();
      if (byOrder.has(orderHash)) return { code: 409, reason: "this order is already being filled" };
      if (byOwner.has(o)) return { code: 409, reason: "one order at a time per wallet - the previous one is still in flight" };
      byOrder.set(orderHash, Date.now());
      byOwner.set(o, orderHash);
      return null;
    },
    release(orderHash, owner) {
      byOrder.delete(orderHash);
      const o = String(owner).toLowerCase();
      if (byOwner.get(o) === orderHash) byOwner.delete(o);
    },
    size: () => ({ orders: byOrder.size, owners: byOwner.size }),
  };
}
