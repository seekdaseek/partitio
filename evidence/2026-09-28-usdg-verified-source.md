# USDG's source is verified on Blockscout, observed 2026-09-28

USDG on Robinhood Chain, `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`, is an EIP-1967 proxy. The
contract behind it is verified on Blockscout and declares `InsufficientFunds()` with no arguments:
the error that `docs/FEEDBACK.md` item 4 is about is public, and only its shape is non-standard.

Verified source:
https://robinhoodchain.blockscout.com/address/0x68184C449E1a8f34fA18d289737129FD27B66f8F?tab=contract

## On chain: the proxy's implementation slot

The slot is `keccak256("eip1967.proxy.implementation") - 1`.

```text
$ cast storage 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc --rpc-url https://rpc.mainnet.chain.robinhood.com
0x00000000000000000000000068184c449e1a8f34fa18d289737129fd27b66f8f
```

Read at 2026-09-28T17:44:48Z.

## The selector

```text
$ cast sig "InsufficientFunds()"
0x356680b7
```

This is the revert data of the refused 1 USDG buy on 2026-09-28 at 14:08 UTC, recorded in
`docs/DEPLOYMENTS.md`.

## Blockscout, read from its own API

Blockscout's API sits behind a Cloudflare check: on 2026-09-28 curl got `HTTP 403` and a "Just a
moment..." page from both the Mac and the VPS. So this ran in a browser tab on
`robinhoodchain.blockscout.com`, which makes the requests same-origin:

```js
const P = '0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168', I = '0x68184C449E1a8f34fA18d289737129FD27B66f8F'; const get = async (u) => (await fetch(u, { headers: { accept: 'application/json' } })).json(); const a = await get('/api/v2/addresses/' + P); const sc = await get('/api/v2/smart-contracts/' + I); const e = (sc.abi || []).filter(x => x.type === 'error' && x.name === 'InsufficientFunds'); ({ fetchedAt: new Date().toISOString(), pageTitle: document.title, pageSaysVerified: /Contract source code verified|Verified/i.test(document.body.innerText), proxy: { address: P, name: a.name, is_verified: a.is_verified, proxy_type: a.proxy_type, implementations: (a.implementations || []).map(i => ({ address: i.address_hash || i.address, name: i.name })) }, implementation: { address: I, name: sc.name, is_verified: sc.is_verified, is_fully_verified: sc.is_fully_verified, verified_at: sc.verified_at, compiler_version: sc.compiler_version, file_path: sc.file_path, abi_entries: (sc.abi || []).length, InsufficientFunds_entries: e } })
```

```json
{
  "fetchedAt": "2026-09-28T17:44:37.690Z",
  "implementation": {
    "InsufficientFunds_entries": [
      {
        "inputs": [],
        "name": "InsufficientFunds",
        "type": "error"
      }
    ],
    "abi_entries": 142,
    "address": "0x68184C449E1a8f34fA18d289737129FD27B66f8F",
    "compiler_version": "v0.8.28+commit.7893614a",
    "file_path": "contracts/stablecoins/USDG.sol",
    "is_fully_verified": true,
    "is_verified": true,
    "name": "USDG",
    "verified_at": "2026-06-26T04:10:34.498250Z"
  },
  "pageSaysVerified": true,
  "pageTitle": "Robinhood Chain address details for 0x68184C449E1a8f34fA18d289737129FD27B66f8F | Blockscout",
  "proxy": {
    "address": "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168",
    "implementations": [
      {
        "address": "0x68184C449E1a8f34fA18d289737129FD27B66f8F",
        "name": "USDG"
      }
    ],
    "is_verified": true,
    "name": "ERC1967Proxy",
    "proxy_type": "eip1967"
  }
}
```
