// Print the relayer's PUBLIC address, and nothing else, from the 0600 key file.
import fs from "node:fs";
import path from "node:path";
const i = process.argv.indexOf("--file");
const f = i > 0 ? process.argv[i + 1] : path.join(path.dirname(new URL(import.meta.url).pathname), "hotkey");
console.log(JSON.parse(fs.readFileSync(f, "utf8")).address);
