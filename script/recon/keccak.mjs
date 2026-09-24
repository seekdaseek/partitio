// keccak256 (Ethereum variant, 0x01 pad) — node's crypto only ships FIPS sha3.
// selfTest() runs known vectors at import; every caller must let it throw.
const MASK = (1n << 64n) - 1n;
const RC = [
  0x0000000000000001n, 0x0000000000008082n, 0x800000000000808an, 0x8000000080008000n,
  0x000000000000808bn, 0x0000000080000001n, 0x8000000080008081n, 0x8000000000008009n,
  0x000000000000008an, 0x0000000000000088n, 0x0000000080008009n, 0x000000008000000an,
  0x000000008000808bn, 0x800000000000008bn, 0x8000000000008089n, 0x8000000000008003n,
  0x8000000000008002n, 0x8000000000000080n, 0x000000000000800an, 0x800000008000000an,
  0x8000000080008081n, 0x8000000000008080n, 0x0000000080000001n, 0x8000000080008008n,
];
const ROTC = [1,3,6,10,15,21,28,36,45,55,2,14,27,41,56,8,25,43,62,18,39,61,20,44];
const PILN = [10,7,11,17,18,3,5,16,8,21,24,4,15,23,19,13,12,2,20,14,22,9,6,1];
const rotl = (x, n) => ((x << BigInt(n)) | (x >> BigInt(64 - n))) & MASK;

function f1600(st) {
  const bc = new Array(5);
  for (let r = 0; r < 24; r++) {
    for (let i = 0; i < 5; i++) bc[i] = st[i] ^ st[i + 5] ^ st[i + 10] ^ st[i + 15] ^ st[i + 20];
    for (let i = 0; i < 5; i++) {
      const t = bc[(i + 4) % 5] ^ rotl(bc[(i + 1) % 5], 1);
      for (let j = 0; j < 25; j += 5) st[j + i] ^= t;
    }
    let t = st[1];
    for (let i = 0; i < 24; i++) {
      const j = PILN[i];
      const tmp = st[j];
      st[j] = rotl(t, ROTC[i]);
      t = tmp;
    }
    for (let j = 0; j < 25; j += 5) {
      for (let i = 0; i < 5; i++) bc[i] = st[j + i];
      for (let i = 0; i < 5; i++) st[j + i] ^= (~bc[(i + 1) % 5] & MASK) & bc[(i + 2) % 5];
    }
    st[0] ^= RC[r];
  }
}

export function keccak256(bytes) {
  const RATE = 136;
  const len = bytes.length;
  const padLen = RATE - (len % RATE);
  const buf = new Uint8Array(len + padLen);
  buf.set(bytes);
  buf[len] ^= 0x01;
  buf[buf.length - 1] ^= 0x80;

  const st = new Array(25).fill(0n);
  for (let off = 0; off < buf.length; off += RATE) {
    for (let i = 0; i < RATE / 8; i++) {
      let lane = 0n;
      for (let b = 7; b >= 0; b--) lane = (lane << 8n) | BigInt(buf[off + i * 8 + b]);
      st[i] ^= lane;
    }
    f1600(st);
  }
  let out = "";
  for (let i = 0; i < 4; i++) {
    const hex = st[i].toString(16).padStart(16, "0");
    for (let b = 7; b >= 0; b--) out += hex.slice(b * 2, b * 2 + 2);
  }
  return "0x" + out;
}

export const hexToBytes = (h) =>
  Uint8Array.from((h.replace(/^0x/, "").match(/../g) || []).map((x) => parseInt(x, 16)));

export function selfTest() {
  const vectors = [
    ["", "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"],
    // PoolKey(TSLA, USDG, 3000, 60, 0) — poolId confirmed against the live chain
    ["0x000000000000000000000000322f0929c4625ed5bad873c95208d54e1c003b2d" +
     "0000000000000000000000005fc5360d0400a0fd4f2af552add042d716f1d168" +
     "0000000000000000000000000000000000000000000000000000000000000bb8" +
     "000000000000000000000000000000000000000000000000000000000000003c" +
     "0000000000000000000000000000000000000000000000000000000000000000",
     "0x8517f8071ae5b831b738052f12125e8e3d6c158b78728aa44ce3b25e5104d32e"],
    // PoolKey(SPY, USDG, 3000, 60, 0)
    ["0x000000000000000000000000117cc2133c37b721f49de2a7a74833232b3b4c0c" +
     "0000000000000000000000005fc5360d0400a0fd4f2af552add042d716f1d168" +
     "0000000000000000000000000000000000000000000000000000000000000bb8" +
     "000000000000000000000000000000000000000000000000000000000000003c" +
     "0000000000000000000000000000000000000000000000000000000000000000",
     "0xfe2a80bb5618fd14984b92ca6d45bf5ba67443ddb1435e28b2e48df2fc1526cd"],
  ];
  for (const [input, want] of vectors) {
    const got = keccak256(hexToBytes(input));
    if (got !== want) {
      throw new Error(`keccak256 self-test FAILED\n  input ${input.slice(0, 40)}...\n  want  ${want}\n  got   ${got}`);
    }
  }
  return vectors.length;
}

selfTest();
