# explorer.mainnet.chain.robinhood.com, observed 2026-09-28

The transaction link a builder would guess, checked from the Mac, from the VPS and in Chromium
between 17:45 and 17:47 UTC. Recorded as observed; no cause is guessed here.

| client | `https://…/tx/<hash>` | `http://…/tx/<hash>` |
|---|---|---|
| curl 8.7.1 with LibreSSL 3.3.6, Mac | TLS alert handshake failure, exit 35 | `301`, `Location: https://robinhoodchain.blockscout.com/` |
| openssl s_client, LibreSSL 3.3.6, Mac | `SSL alert number 40` | |
| curl 8.18.0 with OpenSSL 3.5.5, VPS | TLS alert handshake failure, exit 35 | `301`, `Location: https://robinhoodchain.blockscout.com/` |
| openssl s_client, OpenSSL 3.5.5, VPS | `SSL alert number 40` | |
| Chromium 153.0.8010.12, headless, Mac | `net::ERR_SSL_VERSION_OR_CIPHER_MISMATCH` | lands on `https://robinhoodchain.blockscout.com/`, Blockscout's home page |

Both machines resolve the host through `customer-origin.offchainlabs.com.` to `104.20.46.209` and
`172.66.147.70`.

## The probe, run unchanged on both machines

```bash
#!/bin/bash
# Prints each command exactly as run, its full output, and its own exit code.
H=explorer.mainnet.chain.robinhood.com
TX=0x44e45f1ad396a0d4c37f5a9fc0ce8301d4fb1011702c7cb3d949e15d39ee70fe
run() { printf '$ %s\n' "$1"; bash -c "$1" 2>&1 | tr -d '\r'; printf '(exit %s)\n\n' "${PIPESTATUS[0]}"; }
printf '## %s, %s\n\n' "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
run "curl --version | head -1"
run "curl -sS -o /dev/null -w '%{http_code}\n' https://$H/tx/$TX"
run "openssl version"
run "openssl s_client -connect $H:443 -servername $H < /dev/null"
run "curl -sS -o /dev/null -D - http://$H/tx/$TX"
run "dig +short $H"
```

## Mac

```text
## Mac, macOS 26.6.2, 2026-09-28T17:45:17Z

$ curl --version | head -1
curl 8.7.1 (x86_64-apple-darwin25.0) libcurl/8.7.1 (SecureTransport) LibreSSL/3.3.6 zlib/1.2.12 nghttp2/1.68.1
(exit 0)

$ curl -sS -o /dev/null -w '%{http_code}\n' https://explorer.mainnet.chain.robinhood.com/tx/0x44e45f1ad396a0d4c37f5a9fc0ce8301d4fb1011702c7cb3d949e15d39ee70fe
curl: (35) LibreSSL/3.3.6: error:1404B410:SSL routines:ST_CONNECT:sslv3 alert handshake failure
000
(exit 35)

$ openssl version
LibreSSL 3.3.6
(exit 0)

$ openssl s_client -connect explorer.mainnet.chain.robinhood.com:443 -servername explorer.mainnet.chain.robinhood.com < /dev/null
8282710400:error:1404B410:SSL routines:ST_CONNECT:sslv3 alert handshake failure:/AppleInternal/Library/BuildRoots/4~CVR0ugD7d_x9KkNiDhb6ZUdowAfhsgliSKtR7QU/Library/Caches/com.apple.xbs/TemporaryDirectory.kapob0/Sources/libressl/libressl-3.3/ssl/tls13_lib.c:129:SSL alert number 40
CONNECTED(00000005)
---
no peer certificate available
---
No client certificate CA names sent
---
SSL handshake has read 7 bytes and written 332 bytes
---
New, (NONE), Cipher is (NONE)
Secure Renegotiation IS NOT supported
Compression: NONE
Expansion: NONE
No ALPN negotiated
SSL-Session:
    Protocol  : TLSv1.3
    Cipher    : 0000
    Session-ID: 
    Session-ID-ctx: 
    Master-Key: 
    Start Time: 1790617517
    Timeout   : 7200 (sec)
    Verify return code: 0 (ok)
---
(exit 1)

$ curl -sS -o /dev/null -D - http://explorer.mainnet.chain.robinhood.com/tx/0x44e45f1ad396a0d4c37f5a9fc0ce8301d4fb1011702c7cb3d949e15d39ee70fe
HTTP/1.1 301 Moved Permanently
Date: Mon, 28 Sep 2026 17:45:17 GMT
Content-Type: text/html; charset=UTF-8
Transfer-Encoding: chunked
Connection: keep-alive
Location: https://robinhoodchain.blockscout.com/
Server: cloudflare
CF-RAY: a4248f9e6e6ee44a-OTP

(exit 0)

$ dig +short explorer.mainnet.chain.robinhood.com
customer-origin.offchainlabs.com.
104.20.46.209
172.66.147.70
(exit 0)
```

## VPS

The VPS reply carried Cloudflare's per-response CSP reporting token in three headers; it is
shortened to its first 12 characters and `[...]`, in 3 places. Nothing else is edited.

```text
## VPS solwatch, Ubuntu 26.04 LTS, 2026-09-28T17:45:18Z

$ curl --version | head -1
curl 8.18.0 (x86_64-pc-linux-gnu) libcurl/8.18.0 OpenSSL/3.5.5 zlib/1.3.1 brotli/1.2.0 zstd/1.5.7 libidn2/2.3.8 libpsl/0.21.2 libssh2/1.11.1 nghttp2/1.68.0 librtmp/2.3 mit-krb5/1.22.1 OpenLDAP/2.6.10
(exit 0)

$ curl -sS -o /dev/null -w '%{http_code}\n' https://explorer.mainnet.chain.robinhood.com/tx/0x44e45f1ad396a0d4c37f5a9fc0ce8301d4fb1011702c7cb3d949e15d39ee70fe
curl: (35) TLS connect error: error:0A000410:SSL routines::ssl/tls alert handshake failure
000
(exit 35)

$ openssl version
OpenSSL 3.5.5 27 Jan 2026 (Library: OpenSSL 3.5.5 27 Jan 2026)
(exit 0)

$ openssl s_client -connect explorer.mainnet.chain.robinhood.com:443 -servername explorer.mainnet.chain.robinhood.com < /dev/null
Connecting to 2606:4700:10::6814:2ed1
40776C1386710000:error:0A000410:SSL routines:ssl3_read_bytes:ssl/tls alert handshake failure:../ssl/record/rec_layer_s3.c:918:SSL alert number 40
CONNECTED(00000003)
---
no peer certificate available
---
No client certificate CA names sent
Negotiated TLS1.3 group: <NULL>
---
SSL handshake has read 7 bytes and written 1578 bytes
Verification: OK
---
New, (NONE), Cipher is (NONE)
Protocol: TLSv1.3
This TLS version forbids renegotiation.
Compression: NONE
Expansion: NONE
No ALPN negotiated
Early data was not sent
Verify return code: 0 (ok)
---
(exit 1)

$ curl -sS -o /dev/null -D - http://explorer.mainnet.chain.robinhood.com/tx/0x44e45f1ad396a0d4c37f5a9fc0ce8301d4fb1011702c7cb3d949e15d39ee70fe
HTTP/1.1 301 Moved Permanently
Date: Mon, 28 Sep 2026 17:45:18 GMT
Content-Type: text/html; charset=UTF-8
Transfer-Encoding: chunked
Connection: keep-alive
Location: https://robinhoodchain.blockscout.com/
Report-To: {"group":"cf-csp-endpoint","max_age":86400,"endpoints":[{"url":"https://csp-reporting.cloudflare.com/cdn-cgi/script_monitor/report?m=.IF0f3rg7ZTz[...]"}]}
Reporting-Endpoints: cf-csp-endpoint="https://csp-reporting.cloudflare.com/cdn-cgi/script_monitor/report?m=.IF0f3rg7ZTz[...]"
Content-Security-Policy-Report-Only: script-src 'unsafe-inline' 'unsafe-eval'; connect-src 'none'; report-uri https://csp-reporting.cloudflare.com/cdn-cgi/script_monitor/report?m=.IF0f3rg7ZTz[...]; report-to cf-csp-endpoint
Server: cloudflare
CF-RAY: a4248fa48eb69829-PRG

(exit 0)

$ dig +short explorer.mainnet.chain.robinhood.com
customer-origin.offchainlabs.com.
104.20.46.209
172.66.147.70
(exit 0)
```

## Chromium

```js
// The explorer tx link, https and http, in Playwright's Chromium; where does each land?
const { chromium } = require("/Volumes/D/eternal-demo/node_modules/playwright");
const TX = "0x44e45f1ad396a0d4c37f5a9fc0ce8301d4fb1011702c7cb3d949e15d39ee70fe";
(async () => {
  const b = await chromium.launch();
  for (const scheme of ["https", "http"]) {
    const url = `${scheme}://explorer.mainnet.chain.robinhood.com/tx/${TX}`;
    const p = await b.newPage();
    let err = null;
    try { await p.goto(url, { waitUntil: "domcontentloaded", timeout: 30000 }); await p.waitForTimeout(4000); }
    catch (e) { err = String(e.message).split("\n")[0]; }
    console.log(JSON.stringify({ at: new Date().toISOString(), chromium: b.version(), requested: url,
      landedOn: err ? null : p.url(), title: err ? null : await p.title(), error: err }));
    await p.close();
  }
  await b.close();
})();
```

```text
{"at":"2026-09-28T17:46:58.086Z","chromium":"153.0.8010.12","requested":"https://explorer.mainnet.chain.robinhood.com/tx/0x44e45f1ad396a0d4c37f5a9fc0ce8301d4fb1011702c7cb3d949e15d39ee70fe","landedOn":null,"title":null,"error":"page.goto: net::ERR_SSL_VERSION_OR_CIPHER_MISMATCH at https://explorer.mainnet.chain.robinhood.com/tx/0x44e45f1ad396a0d4c37f5a9fc0ce8301d4fb1011702c7cb3d949e15d39ee70fe"}
{"at":"2026-09-28T17:47:03.482Z","chromium":"153.0.8010.12","requested":"http://explorer.mainnet.chain.robinhood.com/tx/0x44e45f1ad396a0d4c37f5a9fc0ce8301d4fb1011702c7cb3d949e15d39ee70fe","landedOn":"https://robinhoodchain.blockscout.com/","title":"Robinhood Chain blockchain explorer - View Robinhood Chain stats | Blockscout","error":null}
```
