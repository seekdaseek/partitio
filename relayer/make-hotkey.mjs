// Generate the relayer's hot key ON THIS MACHINE. Run on the VPS, by a human:
//   cd /opt/partitio-relayer && node relayer/make-hotkey.mjs
//
// The key is written to relayer/hotkey with mode 0600 and never printed, logged or sent anywhere;
// only the public address is printed. It refuses to overwrite an existing key, because a
// replaced key strands whatever float the old one held.
import fs from "node:fs";
import path from "node:path";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";

const i = process.argv.indexOf("--out");
const out = i > 0 ? process.argv[i + 1] : path.join(path.dirname(new URL(import.meta.url).pathname), "hotkey");
if (fs.existsSync(out)) {
  console.error(`${out} already exists - refusing to overwrite (it may hold the float)`);
  process.exit(1);
}
const key = generatePrivateKey();
const address = privateKeyToAccount(key).address;
fs.writeFileSync(out, JSON.stringify({ address, private_key: key }) + "\n", { mode: 0o600, flag: "wx" });
console.log(address);
