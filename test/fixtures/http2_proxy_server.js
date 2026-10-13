const http = require('node:http');
const http2 = require('node:http2');
const https = require('node:https');
const net = require('node:net');
const fs = require('node:fs');
const crypto = require('node:crypto');
const mode = process.argv[2] || 'h2';
const authenticated = process.argv.includes('auth');
const secureProxy = process.argv.includes('secure');
let failOnce = process.argv.includes('fail-once');
const tls = { key: fs.readFileSync('test/fixtures/http2-local-key.pem'),
  cert: fs.readFileSync('test/fixtures/http2-local-cert.pem') };
let tunnels = 0;
let leaked = false;
const held = [];
require('node:readline').createInterface({ input: process.stdin }).on('line', line => {
  if (line === 'release') for (const res of held.splice(0)) res.end('suffix');
});
const handleOrigin = (req, res) => {
  leaked ||= req.headers['proxy-authorization'] !== undefined;
  if (req.url === '/echo') {
    const chunks = [];
    req.on('data', chunk => chunks.push(chunk));
    req.on('end', () => {
      const body = Buffer.concat(chunks);
      res.end(JSON.stringify({ length: body.length,
        hash: crypto.createHash('sha256').update(body).digest('hex'), leaked }));
    });
    return;
  }
  if (req.url === '/stream') {
    res.writeHead(200); res.flushHeaders(); res.write('prefix'); return;
  }
  if (req.url === '/held') {
    res.writeHead(200); res.flushHeaders(); res.write('prefix'); held.push(res); return;
  }
  if (req.url === '/redirect') { res.writeHead(302, { location: '/' }); res.end(); }
  else res.end(JSON.stringify({ protocol: mode, tunnels, leaked }));
};
const origin = mode === 'plain' ? http.createServer(handleOrigin) :
  mode === 'h1' ? https.createServer(tls, handleOrigin) : http2.createSecureServer(tls);
if (mode === 'h2') origin.on('stream', (stream, headers) => {
  stream.on('error', () => {});
  leaked ||= headers['proxy-authorization'] !== undefined;
  if (headers[':path'] === '/redirect') {
    stream.respond({ ':status': 302, location: '/' }); stream.end(); stream.resume(); return;
  }
  stream.respond({ ':status': 200 });
  stream.end(JSON.stringify({ protocol: 'h2', tunnels, leaked }));
  stream.resume();
});
const reject = (req, res) => { res.writeHead(502); res.end(); };
const proxyTls = { key: fs.readFileSync('test/fixtures/https-proxy-local-key.pem'),
  cert: fs.readFileSync('test/fixtures/https-proxy-local-cert.pem') };
const proxy = secureProxy ? https.createServer(proxyTls, reject) : http.createServer(reject);
proxy.on('tlsClientError', () => {});
proxy.on('connect', (req, client, head) => {
  client.on('error', () => {});
  if (failOnce) {
    failOnce = false;
    client.end('HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n');
    return;
  }
  if (authenticated && req.headers['proxy-authorization'] !==
      'Basic ' + Buffer.from('u:p@ss').toString('base64')) {
    client.end('HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm="test"\r\nContent-Length: 0\r\n\r\n');
    return;
  }
  if (req.url !== `localhost:${origin.address().port}`) {
    client.end('HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n');
    return;
  }
  tunnels++;
  const upstream = net.connect(origin.address().port, '127.0.0.1', () => {
    client.write('HTTP/1.1 200 Connection Established\r\n\r\n');
    if (head.length) upstream.write(head);
    client.pipe(upstream);
    upstream.pipe(client);
  });
  upstream.on('error', () => client.destroy());
  client.on('close', () => upstream.destroy());
});
origin.listen(0, '127.0.0.1', () => proxy.listen(0, '127.0.0.1', () =>
  console.log(JSON.stringify({ origin: origin.address().port, proxy: proxy.address().port }))));
