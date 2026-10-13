// Node's ECMAScript Number.toString oracle. No service credentials required.
const fs = require('node:fs');
const vectors = [];
function append(bits) {
  const bytes = Buffer.alloc(8);
  bytes.writeBigUInt64BE(bits);
  vectors.push({ bits: bytes.toString('hex'), text: String(bytes.readDoubleBE()) });
}
for (const number of [
  0, -0, NaN, Infinity, -Infinity, Number.MIN_VALUE, Number.MAX_VALUE,
  Number.MIN_SAFE_INTEGER, Number.MAX_SAFE_INTEGER, 1e-7, 1e-6, 1e20, 1e21,
  1000000000000000128, 2.2250738585072014e-308,
]) {
  const bytes = Buffer.alloc(8);
  bytes.writeDoubleBE(number);
  append(bytes.readBigUInt64BE());
}
let seed = 0x123456789abcdefn;
const mask = (1n << 64n) - 1n;
for (let i = 0; i < 2048; i++) {
  seed ^= seed << 13n;
  seed &= mask;
  seed ^= seed >> 7n;
  seed ^= seed << 17n;
  seed &= mask;
  append(seed);
}
fs.writeFileSync('test/js_number_vectors.json', JSON.stringify(vectors, null, 2) + '\n');
