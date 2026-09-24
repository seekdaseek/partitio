#!/usr/bin/env bash
# Re-pin to a fresh block and run a subset of the suite.
# The canonical 4663 RPC is not an archive node (see script/pin.sh): a pin ages out in ~90 min,
# so every review run re-pins rather than inheriting a stale block number.
set -euo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
RPC="${PARTITIO_RPC:-https://rpc.mainnet.chain.robinhood.com}"
PIN="${PARTITIO_PIN:-$(( $(cast block-number --rpc-url "$RPC") - 60 ))}"
echo "fork: $RPC @ $PIN"
exec forge test --fork-url "$RPC" --fork-block-number "$PIN" "$@"
