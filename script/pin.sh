#!/usr/bin/env bash
# Pick a fork pin block and run the suite against it.
#
# The canonical 4663 RPC is NOT an archive node: measured 2026-09-24 it serves state for roughly
# the last 5,000-20,000 blocks (head-5000 OK, head-20000 refused), i.e. under ~90 minutes of chain.
# Foundry's fork cache only holds slots a previous run actually touched, so a different test at the
# same "pinned" block still reaches for the RPC and fails once the block ages out.
#
# Consequences, stated rather than hidden:
#   - PARTITIO_PIN unset  -> pin to head-150, reproducible for about the next hour.
#   - PARTITIO_PIN set    -> that block, which requires either a warm cache or an archive RPC.
#   - PARTITIO_RPC set    -> use an archive provider and any pin becomes durable.
set -euo pipefail
RPC="${PARTITIO_RPC:-https://rpc.mainnet.chain.robinhood.com}"
export PATH="$HOME/.foundry/bin:$PATH"
if [ -n "${PARTITIO_PIN:-}" ]; then PIN="$PARTITIO_PIN"
else
  HEAD=$(cast block-number --rpc-url "$RPC")
  PIN=$((HEAD - 150))
  echo "no PARTITIO_PIN set; pinning to head-150 = $PIN (valid ~1h on a non-archive RPC)"
fi
echo "fork: $RPC @ $PIN"
exec forge test --fork-url "$RPC" --fork-block-number "$PIN" "$@"
