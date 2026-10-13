const http2 = require('node:http2');
const fs = require('node:fs');
const server = http2.createSecureServer({
  key: fs.readFileSync('test/fixtures/http2-local-key.pem'),
  cert: fs.readFileSync('test/fixtures/http2-local-cert.pem'),
});
let sessions = 0;
const ids = new WeakMap();
let held;
let drainingSession;
let oldClosed = false;
server.on('session', session => {
  ids.set(session, ++sessions);
  session.on('error', () => {});
  session.on('close', () => { if (ids.get(session) === 1) oldClosed = true; });
});
server.on('stream', (stream, headers) => {
  stream.on('error', () => {});
  const session = stream.session;
  const id = ids.get(session);
  stream.resume();
  stream.on('end', () => {
    if (headers[':path'] === '/hold') {
      held = stream;
      drainingSession = session;
      stream.respond({ ':status': 200, 'x-session': id });
      stream.write('held');
    } else if (headers[':path'] === '/goaway') {
      session.goaway(http2.constants.NGHTTP2_NO_ERROR, stream.id);
      stream.respond({ ':status': 200, 'x-session': id });
      stream.end('goaway');
    } else {
      if (headers[':path'] === '/release' && held) {
        held.end('released', () => drainingSession.close());
      }
      stream.respond({ ':status': 200, 'x-session': id, 'x-old-closed': String(oldClosed) });
      stream.end(String(id));
    }
  });
});
server.listen(0, '127.0.0.1', () => console.log(server.address().port));
