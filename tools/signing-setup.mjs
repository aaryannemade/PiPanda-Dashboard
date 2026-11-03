// Fetch current Bambu application signing credentials for a user's dashboard.
// Run through `nix develop --command just signing-setup` after login.
// Protocol references (independent implementation, no upstream library code):
// https://github.com/lordbagel42/bambu-rea/blob/main/pkg/bambu/cloud/iotcert.go
// https://github.com/ClusterM/open-bamboo-networking/blob/master/research/10.02-secrets.md
// The public application bootstrap identity is not a user/printer credential.
import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";

const APP_ID = "GLOF3813734089-af70cf3b000006c7d872272593fe";
const SERVICE_CERT = `-----BEGIN CERTIFICATE-----
MIIDeTCCAmGgAwIBAgIUGpX26HEycYnaaCUFwJr8F/UPCZIwDQYJKoZIhvcNAQEL
BQAwKDEmMCQGA1UEAwwdYXBwbGljYXRpb25fcm9vdC5iYW1idWxhYi5jb20wHhcN
MjQwNzI2MDE1MjI3WhcNMzQwNzI0MDE1MjI3WjAfMR0wGwYDVQQDDBRzZXJ2aWNl
LmJhbWJ1bGFiLmNvbTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAJ2z
wQvNAjA9lQe06o/Vv6JULHLn25NK706myDa4i9lmb3wqARNVi6aSWfxO3Cz9NklC
4dYAdFbgcEUXuJIcJBBZdgPO2GhnaeCUVWz/ucW2GCdPaBAkXZNDK56aPqfYwltI
sNJcUIvq0OmbFsI90l8zKTQzd8/zJcfm8lOBpAberwbEeHCQfDxUWpNyrAuGJlkD
cmxraAjzBXQjAyMT+kK+KPOqhJICu5SXP87WGlzw8sfrdLl7J2vhtXpzRC67vtv6
uD6aqq5f2OaRxHRUyqeDY/adiWE9Qeb9amkRMcQiUJ0IQJZ4wDSMNpZe0guXLkl5
LPdPU249Bu86H5eDf5ECAwEAAaOBozCBoDAJBgNVHRMEAjAAMAsGA1UdDwQEAwID
uDAdBgNVHQ4EFgQUb/FHYnyT++aiAcbhmQsDIMw/C+kwZwYDVR0jBGAwXqFGpEQw
QjELMAkGA1UEBhMCQ04xIjAgBgNVBAoMGUJCTCBUZWNobm9sb2dpZXMgQ28uLCBM
dGQxDzANBgNVBAMMBkJCTCBDQYIUGpX26HEycYnaaCUFwJr8F/UPCYgwDQYJKoZI
hvcNAQELBQADggEBAK3n3LsRPiT9dEKrteCvBhaO/nAhc3Ogpi5iw4yiSB6abIHy
a36oGCA7RDMaMizDxbmWqooasA3xWnWLaf83FPt8KTnG72hmRb/usjc8sqFQQPPX
/VZf8ITAILx7Nrh1yLKI31UtYLMgeGNA8sifQUVJFOLqcwEpqUvII5ZK1YZ/27lM
gmscseUC5s4MTVf+aT5Gxg/v8MI0kgzNKCUELx7HuMfz/Og7+BSS58piZ1vt8Mgq
VvhUVmCS9SnCnvkM57zOumHHlvoSf7u6eq7YQd6spdJBYS1Yf2KGxKG2uooT9VlX
Gq8Fcpo0F9pzYXX3kKeBJo1vl1/R54eAgd82rNg=
-----END CERTIFICATE-----`;

// Bambu's key-blob format is AES-256-CTR with this nonstandard substitution
// table and fixed wrapping key 00..1f. This is separate from request AES-GCM.
const SUBSTITUTION = Buffer.from(
  "c5574d6c3a9505e0a3ba361fea51533b0e074e64500440e8626e9f2d708b2849" +
  "d5f9658d74687c6f0a6ab3af38fe7e8a477fb01600d40f13c9804aac8c4fa798" +
  "83945d48b4e93019039925bf8e41a0e4c3cf2cabd2321a0c11b5566315a6690b" +
  "88bb4c10cb75fa81f8cda1d697b726c69ef15fe5a987c7dc8f7a86209ad108c2" +
  "8409331bdd1efd0171da770dd7de93caa5d0e6608937c821597996ad2434b944" +
  "fcc1aef382464331e32e4bfb9255ed45766daa3ff55a91782206ffd9357d7bdb" +
  "54129cd8d3ee1742523ea4e7df9df2f4ef73f65eb15b18e29b58a82ae13d90b6" +
  "1cbd61eb23a26739f0bcb2f7852772cc29b81dbe66c42fce143c6bec5c2bc002", "hex",
);

const xtime = (byte) => ((byte << 1) ^ (byte & 128 ? 0x1b : 0)) & 255;

function blobRoundKeys() {
  const expanded = Uint8Array.from({ length: 240 }, (_, i) => i < 32 ? i : 0);
  let rcon = 1;
  for (let offset = 32; offset < expanded.length; offset += 4) {
    let word = Array.from(expanded.slice(offset - 4, offset));
    if (offset % 32 === 0) {
      word = [SUBSTITUTION[word[1]] ^ rcon, SUBSTITUTION[word[2]], SUBSTITUTION[word[3]], SUBSTITUTION[word[0]]];
      rcon = xtime(rcon);
    } else if (offset % 32 === 16) word = word.map((v) => SUBSTITUTION[v]);
    for (let i = 0; i < 4; i++) expanded[offset + i] = expanded[offset - 32 + i] ^ word[i];
  }
  return expanded;
}

function blobBlock(input, keys) {
  let state = Uint8Array.from(input, (byte, i) => byte ^ keys[i]);
  for (let round = 1; round <= 14; round++) {
    const shifted = new Uint8Array(16);
    for (let column = 0; column < 4; column++) {
      for (let row = 0; row < 4; row++) shifted[column * 4 + row] = SUBSTITUTION[state[((column + row) % 4) * 4 + row]];
    }
    state = shifted;
    if (round !== 14) {
      for (let i = 0; i < 16; i += 4) {
        const [a, b, c, d] = state.slice(i, i + 4);
        const total = a ^ b ^ c ^ d;
        state[i] = a ^ total ^ xtime(a ^ b);
        state[i + 1] = b ^ total ^ xtime(b ^ c);
        state[i + 2] = c ^ total ^ xtime(c ^ d);
        state[i + 3] = d ^ total ^ xtime(d ^ a);
      }
    }
    for (let i = 0; i < 16; i++) state[i] ^= keys[round * 16 + i];
  }
  return Buffer.from(state);
}

function decodeBlob(encoded) {
  const blob = Buffer.from(encoded, "base64");
  if (blob.length < 64 || blob.readUInt32LE(28) !== blob.length - 32) throw new Error("Invalid key-blob framing");
  const plaintext = Buffer.alloc(blob.length - 32);
  const keys = blobRoundKeys();
  for (let offset = 0; offset < plaintext.length; offset += 16) {
    const counter = Buffer.alloc(16);
    blob.copy(counter, 0, 0, 12);
    counter.writeUInt32BE(2 + offset / 16, 12);
    const block = blobBlock(counter, keys);
    for (let i = 0; i < Math.min(16, plaintext.length - offset); i++) plaintext[offset + i] = blob[32 + offset + i] ^ block[i];
  }
  if (plaintext.readUInt32LE(0) !== 0x534b4559 || plaintext.readUInt32LE(4) !== 1) throw new Error("Unsupported signing key-blob format");
  return plaintext;
}

function privateKeyFromBlob(blob) {
  const data = decodeBlob(blob);
  try {
    const width = data.readUInt32LE(12);
    if (width < 64 || width > 256 || data.length !== 32 + 5 * width) throw new Error("Invalid RSA CRT lengths");
    for (let i = 0; i < 5; i++) if (data.readUInt32LE(12 + i * 4) !== width) throw new Error("Unequal RSA CRT lengths");
    const fields = Array.from({ length: 5 }, (_, i) => data.subarray(32 + i * width, 32 + (i + 1) * width));
    const [p, q] = fields.map((bytes) => BigInt(`0x${bytes.toString("hex")}`));
    const gcd = (a, b) => b ? gcd(b, a % b) : a;
    const modulus = (p - 1n) / gcd(p - 1n, q - 1n) * (q - 1n);
    let [t, nextT, r, nextR] = [0n, 1n, modulus, 65537n];
    while (nextR) {
      const quotient = r / nextR;
      [t, nextT] = [nextT, t - quotient * nextT];
      [r, nextR] = [nextR, r - quotient * nextR];
    }
    if (r !== 1n) throw new Error("Invalid RSA exponent");
    const encodeInt = (value, size) => Buffer.from(value.toString(16).padStart(size * 2, "0"), "hex").toString("base64url");
    return crypto.createPrivateKey({ format: "jwk", key: {
      kty: "RSA", n: encodeInt(p * q, width * 2), e: "AQAB", d: encodeInt((t % modulus + modulus) % modulus, width * 2),
      p: fields[0].toString("base64url"), q: fields[1].toString("base64url"),
      dp: fields[2].toString("base64url"), dq: fields[3].toString("base64url"), qi: fields[4].toString("base64url"),
    } });
  } finally { data.fill(0); }
}

async function setup() {
  const dir = process.env.PIPANDA_STATE_DIR;
  if (!dir) throw new Error("Run this using nix develop --command just signing-setup");
  const credentials = JSON.parse(await fs.readFile(path.join(dir, "credentials.json"), "utf8"));
  const sessionKey = crypto.randomBytes(32);
  const nonce = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv("aes-256-gcm", sessionKey, nonce);
  const encrypted = Buffer.concat([cipher.update(APP_ID), cipher.final()]);
  // Bambu requires URL-safe base64 WITH '=' padding (not Node's base64url).
  const url64 = (bytes) => bytes.toString("base64").replaceAll("+", "-").replaceAll("/", "_");
  const appKey = url64(Buffer.concat([nonce, encrypted, cipher.getAuthTag()]));
  const wrapped = url64(crypto.publicEncrypt({ key: SERVICE_CERT, padding: crypto.constants.RSA_PKCS1_PADDING }, sessionKey));
  sessionKey.fill(0);
  const host = credentials.region === "china" ? "https://api.bambulab.cn" : "https://api.bambulab.com";
  const response = await fetch(`${host}/v1/iot-service/api/user/applications/${appKey}/cert?aes256=${wrapped}&ver=1`, {
    signal: AbortSignal.timeout(30_000),
    headers: {
      Authorization: `Bearer ${credentials.access_token}`, "User-Agent": "Handy/4.3.0", Accept: "application/json",
      "X-BBL-Client-Type": "app", "X-BBL-Client-Name": "BambuHandy", "X-BBL-Client-Version": "4.3.0",
      "X-BBL-Client-Release-Code": "40300", "X-BBL-OS-Type": "Android", "X-BBL-OS-Version": "14",
      "X-BBL-Device-Brand": "samsung", "X-BBL-Device-Model": "SM-G991B", "X-BBL-Language": "en-GB", "X-BBL-Device-ID": crypto.randomUUID(),
    },
  });
  const result = await response.json();
  if (!response.ok || result.code !== 0 || !result.cert || !result.key) throw new Error(`Certificate service rejected provisioning (HTTP ${response.status}, code ${result.code ?? "unknown"})`);
  const key = privateKeyFromBlob(result.key);
  const leaf = new crypto.X509Certificate(result.cert);
  const probe = Buffer.from("pipanda signing credential verification");
  if (!crypto.verify("RSA-SHA256", probe, leaf.publicKey, crypto.sign("RSA-SHA256", probe, key))) throw new Error("Private key does not match certificate");
  if (Date.parse(leaf.validTo) <= Date.now() || Date.parse(leaf.validFrom) > Date.now()) throw new Error("Certificate is not currently valid");
  const crl = Array.isArray(result.crl) ? result.crl.join("\n") : result.crl;
  if (typeof crl !== "string" || !crl.includes("BEGIN X509 CRL")) throw new Error("Missing certificate revocation list");
  const issuer = leaf.issuer;
  if (!/^CN=[^\n]+$/.test(issuer)) throw new Error("Unsupported certificate issuer");
  const serial = leaf.serialNumber.toLowerCase();
  const id = serial.padStart(serial.length + serial.length % 2, "0") + issuer;
  const files = {
    "slicer_cert.pem": result.cert,
    "slicer_crl.pem": crl,
    "slicer_cert_id.txt": id + "\n",
    "slicer_key.pem": key.export({ type: "pkcs8", format: "pem" }),
  };
  for (const [name, content] of Object.entries(files)) {
    const destination = path.join(dir, name);
    const staging = `${destination}.${crypto.randomUUID()}.tmp`;
    try {
      await fs.writeFile(staging, content, { mode: 0o600, flag: "wx" });
      await fs.rename(staging, destination);
    } finally { await fs.unlink(staging).catch(() => {}); }
  }
  console.log(`Signing credentials saved privately in ${dir}. Valid until ${leaf.validTo}. Restart the backend to use them.`);
}

if (process.argv.includes("--self-test")) {
  const counter = Buffer.from("303c8f522a171b9a40dc890100000002", "hex");
  if (blobBlock(counter, blobRoundKeys()).toString("hex") !== "c6bf1cc1b40dcc16443034d6dabe7b81") throw new Error("Key-blob cipher known-answer test failed");
  console.log("Signing provisioning cipher known-answer test passed (no network requests).");
} else {
  try { await setup(); } catch (error) {
    // Never print fetch errors/stack traces: request URLs contain wrapped keys.
    const message = error instanceof TypeError ? "Certificate request failed" : error.message;
    console.error(`Signing setup failed: ${message}`);
    process.exitCode = 1;
  }
}
