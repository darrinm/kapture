// Mints a share token for one owner: prints the secret to paste into Kapture and the
// sha256 hash to put in the Worker's TOKENS secret. The server only ever sees the hash.
import { randomBytes, createHash } from "node:crypto";

const owner = process.argv[2];
if (!owner || !/^[a-z0-9_-]{1,32}$/i.test(owner)) {
  console.error("usage: node scripts/mint-token.mjs <owner>   (letters, digits, - and _)");
  process.exit(1);
}

const token = randomBytes(24).toString("base64url");
const hash = createHash("sha256").update(token).digest("hex");

console.log(`owner:  ${owner}`);
console.log(`token:  ${token}        <- paste into Kapture › Settings › Sharing`);
console.log(`hash:   ${hash}`);
console.log(`\nTOKENS entry:  ${JSON.stringify({ [owner]: hash })}`);
