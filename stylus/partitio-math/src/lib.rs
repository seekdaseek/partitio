//! PartitioMath — the greedy split allocator, in Stylus.
//!
//! Identical algorithm to `src/lib/GreedySplit.sol`, compiled to WASM. The point is the gas
//! table: the allocator is the hot loop of a route (K chunks x V venues of comparisons) and it
//! is pure arithmetic, which is where Stylus should beat the EVM. Both implementations are
//! deployed so the comparison is measured, not asserted.
//!
//! Ladders are passed FLATTENED: `ladders[v][n]` lives at `flat[v * k + n]`, and a zero entry
//! means the venue cannot fill that size and is capped there.
#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
extern crate alloc;

use alloc::vec::Vec;
use stylus_sdk::{alloy_primitives::U256, prelude::*};

#[storage]
#[entrypoint]
pub struct PartitioMath;

#[public]
impl PartitioMath {
    /// Greedy marginal allocation over a flattened ladder.
    /// Returns the chunk count assigned to each venue, then the predicted total as the last word.
    pub fn allocate(&self, flat: Vec<U256>, venues: u32, k: u32) -> Vec<U256> {
        let v = venues as usize;
        let k = k as usize;
        let mut alloc: Vec<usize> = Vec::with_capacity(v);
        alloc.resize(v, 0);

        if v == 0 || k == 0 || flat.len() < v * k {
            let mut out: Vec<U256> = Vec::with_capacity(v + 1);
            out.resize(v + 1, U256::ZERO);
            return out;
        }

        let rung = |vi: usize, n: usize| -> U256 { flat[vi * k + n - 1] };

        for _ in 0..k {
            let mut best_v = usize::MAX;
            let mut best_gain = U256::ZERO;
            for vi in 0..v {
                let n = alloc[vi];
                if n >= k {
                    continue;
                }
                let next = rung(vi, n + 1);
                if next.is_zero() {
                    continue; // venue capped at this size
                }
                let cur = if n == 0 { U256::ZERO } else { rung(vi, n) };
                if n != 0 && cur.is_zero() {
                    continue; // capped earlier: never step over a hole
                }
                if next <= cur {
                    continue; // never allocate into a loss
                }
                let gain = next - cur;
                if gain > best_gain {
                    best_gain = gain;
                    best_v = vi;
                }
            }
            if best_v == usize::MAX {
                break; // nothing improves
            }
            alloc[best_v] += 1;
        }

        let mut total = U256::ZERO;
        let mut out: Vec<U256> = Vec::with_capacity(v + 1);
        for vi in 0..v {
            if alloc[vi] != 0 {
                total += rung(vi, alloc[vi]);
            }
            out.push(U256::from(alloc[vi] as u64));
        }
        out.push(total);
        out
    }
}
