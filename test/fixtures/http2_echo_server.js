// Native Node HTTP/2 peer for multi-megabyte Dart interoperability tests.
const http2 = require('node:http2');
const fs = require('node:fs');
const server = http2.createSecureServer({
  key: fs.readFileSync('test/fixtures/http2-local-key.pem'),
  cert: fs.readFileSync('test/fixtures/http2-local-cert.pem'),
});
server.on('stream', stream => {
  const chunks = [];
  stream.on('error', () => {});
  stream.on('data', chunk => chunks.push(chunk));
  stream.on('end', () => {
    const body = Buffer.concat(chunks);
    stream.respond({ ':status': 200, 'content-length': body.length });
    stream.end(body);
  });
});
server.listen(0, '127.0.0.1', () => console.log(server.address().port));
