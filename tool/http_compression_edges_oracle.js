// Generate Node fetch decompression edge vectors using local HTTP only.
const http = require('node:http');
const zlib = require('node:zlib');
const fs = require('node:fs');
const plain = Buffer.from('compressed edge 世界 '.repeat(8));
const inputs = [];
for (const [encoding, compress] of [
  ['gzip', zlib.gzipSync], ['deflate', zlib.deflateSync],
  ['deflate', zlib.deflateRawSync],
]) {
  const data = compress(plain);
  for (const length of [...new Set([0, 1, 2, 5, Math.floor(data.length / 2), data.length - 8, data.length - 1, data.length])]) {
    inputs.push({ encoding, input: data.subarray(0, length), label: `length=${length}/${data.length}` });
  }
  const corrupt = Buffer.from(data); corrupt[Math.floor(data.length / 2)] ^= 255;
  inputs.push({ encoding, input: corrupt, label: 'corrupt-middle' });
}
(async () => {
  const server = http.createServer((req, res) => {
    const item = inputs[Number(req.url.slice(1))];
    res.writeHead(200, { 'content-encoding': item.encoding }); res.end(item.input);
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const results = [];
  try {
    for (let index = 0; index < inputs.length; index++) {
      const item = inputs[index];
      const result = { encoding: item.encoding, label: item.label, input: item.input.toString('base64') };
      try {
        const response = await fetch(`http://127.0.0.1:${server.address().port}/${index}`);
        result.output = Buffer.from(await response.arrayBuffer()).toString('base64');
      } catch (error) { result.error = error.cause?.code || error.name; }
      results.push(result);
    }
  } finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
  fs.writeFileSync(process.argv[2], JSON.stringify({ node: process.version, vectors: results }, null, 2) + '\n');
})().catch(error => { console.error(error); process.exitCode = 1; });
