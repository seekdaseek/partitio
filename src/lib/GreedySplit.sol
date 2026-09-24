// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title GreedySplit
/// @notice Marginal-output allocation across venues.
///
/// The input is a per-venue LADDER: `ladders[v][n-1]` is the output venue v returns for exactly
/// `n` chunks of the input. A 0 entry means the venue could not or would not fill that size (a
/// Rialto maker declining, or a quoter revert recorded upstream), and it caps the venue there:
/// the allocator will not allocate past a zero rung.
///
/// This is GREEDY, not optimal. It allocates one chunk at a time to whichever venue offers the
/// largest marginal gain. With concave per-venue output curves (which AMM curves are) greedy is
/// optimal; with hook pools that can price non-monotonically it is not, and no claim is made that
/// it is. The bound is K: at most K chunks, so at most K venues, and resolution is amountIn/K.
library GreedySplit {
    /// @param ladders ladders[v][n-1] = output of venue v for n chunks. 0 = unavailable at that size.
    /// @param k number of chunks to allocate.
    /// @return alloc chunks assigned per venue.
    /// @return total summed output of the allocation.
    function allocate(uint256[][] memory ladders, uint256 k)
        internal
        pure
        returns (uint256[] memory alloc, uint256 total)
    {
        uint256 v = ladders.length;
        alloc = new uint256[](v);

        for (uint256 c = 0; c < k; c++) {
            uint256 bestV = type(uint256).max;
            uint256 bestGain = 0;
            for (uint256 i = 0; i < v; i++) {
                uint256 n = alloc[i];
                if (n >= ladders[i].length) continue;          // ladder exhausted
                uint256 next = ladders[i][n];                  // output at n+1 chunks
                if (next == 0) continue;                       // venue capped here
                uint256 cur = n == 0 ? 0 : ladders[i][n - 1];
                if (cur == 0 && n != 0) continue;              // capped earlier; do not step over a hole
                if (next <= cur) continue;                     // no gain: never allocate into a loss
                uint256 gain = next - cur;
                if (gain > bestGain) { bestGain = gain; bestV = i; }
            }
            if (bestV == type(uint256).max) break;              // nothing improves: stop early
            alloc[bestV]++;
        }

        for (uint256 i = 0; i < v; i++) {
            if (alloc[i] != 0) total += ladders[i][alloc[i] - 1];
        }
    }
}
