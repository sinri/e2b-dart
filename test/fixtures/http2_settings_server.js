const http2 = require('node:http2');
const fs = require('node:fs');
const readline = require('node:readline');
const server = http2.createSecureServer({
  key: fs.readFileSync('test/fixtures/http2-local-key.pem'),
  cert: fs.readFileSync('test/fixtures/http2-local-cert.pem'),
  settings: { maxConcurrentStreams: 0 },
});
let session;
let sessions = 0;
let held;
server.on('session', current => {
  session = current;
  sessions++;
  current.on('error', () => {});
  current.on('localSettings', settings =>
    console.log(`settings:${settings.maxConcurrentStreams}`));
});
server.on('stream', (stream, headers) => {
  stream.on('error', () => {});
  stream.resume();
  stream.respond({ ':status': 200, 'x-sessions': String(sessions) });
  if (headers[':path'] === '/hold') {
    held = stream;
    stream.write('prefix');
  } else {
    stream.end('ok');
  }
});
readline.createInterface({ input: process.stdin }).on('line', line => {
  if (line === 'release') {
    held.end('tail');
  } else if (line.startsWith('limit ')) {
    session.settings({ maxConcurrentStreams: Number(line.slice(6)) });
  }
});
server.listen(0, '127.0.0.1', () => console.log(server.address().port));
