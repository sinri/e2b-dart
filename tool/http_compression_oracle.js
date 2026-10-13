// Node fetch reference for native HTTP/2 response adaptation. Local traffic only.
const http = require('node:http');
const zlib = require('node:zlib');
const plain = Buffer.from('hello世界');
const cases = [
  ['gzip', zlib.gzipSync(plain)],
  ['GZIP', zlib.gzipSync(plain)],
  ['x-gzip', zlib.gzipSync(plain)],
  ['deflate', zlib.deflateSync(plain)],
  ['x-deflate', zlib.deflateSync(plain)],
  ['deflate', zlib.deflateRawSync(plain)],
  ['gzip, deflate', zlib.deflateSync(zlib.gzipSync(plain))],
  ['br', zlib.brotliCompressSync(plain)],
  ['BR', zlib.brotliCompressSync(plain)],
  ['gzip, br', zlib.brotliCompressSync(zlib.gzipSync(plain))],
];
(async () => {
  const server = http.createServer((req, res) => {
    const [encoding, body] = cases[Number(req.url.slice(1))];
    res.writeHead(200, { 'content-encoding': encoding, 'content-length': body.length });
    res.end(body);
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  try {
    for (let index = 0; index < cases.length; index++) {
      const response = await fetch(`http://127.0.0.1:${server.address().port}/${index}`);
      const body = Buffer.from(await response.arrayBuffer());
      console.log(JSON.stringify({
        index, encoding: response.headers.get('content-encoding'),
        contentLength: response.headers.get('content-length'),
        decoded: body.equals(plain),
      }));
      if (body.equals(plain) !== (cases[index][0] !== 'x-deflate')) {
        throw Error(`case ${index} differs from expected decoding`);
      }
    }
    // A decoder must produce bytes before EOF: buffering the whole compressed
    // response would deadlock this server/client exchange.
    let release;
    const released = new Promise(resolve => { release = resolve; });
    const streaming = http.createServer(async (req, res) => {
      res.writeHead(200, { 'content-encoding': 'br' });
      const encoder = zlib.createBrotliCompress();
      encoder.pipe(res);
      encoder.write(plain);
      encoder.flush(zlib.constants.BROTLI_OPERATION_FLUSH, async () => {
        await released;
        encoder.end(Buffer.from('tail'));
      });
    });
    await new Promise(resolve => streaming.listen(0, '127.0.0.1', resolve));
    try {
      const response = await fetch(
        `http://127.0.0.1:${streaming.address().port}/`,
        { signal: AbortSignal.timeout(5000) });
      const reader = response.body.getReader();
      const first = await reader.read();
      if (first.done || !Buffer.from(first.value).equals(plain)) {
        throw Error('Brotli did not emit the flushed prefix before EOF');
      }
      release();
      const remaining = [];
      for (;;) {
        const next = await reader.read();
        if (next.done) break;
        remaining.push(Buffer.from(next.value));
      }
      if (Buffer.concat(remaining).toString() !== 'tail') {
        throw Error('Brotli streaming tail differs');
      }
      console.log(JSON.stringify({ encoding: 'br', emitsBeforeEof: true }));
    } finally {
      release();
      streaming.closeAllConnections();
      await new Promise(resolve => streaming.close(resolve));
    }
  } finally {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
