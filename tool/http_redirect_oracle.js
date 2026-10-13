// Local Node fetch reference. Writes deterministic method/body redirect vectors.
const http = require('node:http');
const fs = require('node:fs');
(async () => {
  const server = http.createServer(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    if (req.url.startsWith('/redirect/')) {
      res.writeHead(Number(req.url.split('/').pop()), { location: '/target' });
      res.end();
    } else {
      res.setHeader('content-type', 'application/json');
      // HEAD has no response body; capture its request separately.
      server.lastRequest = { method: req.method, body: Buffer.concat(chunks).toString() };
      res.end(JSON.stringify(server.lastRequest));
    }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const rows = [];
  try {
    for (const status of [301, 302, 303, 307, 308]) {
      for (const method of ['POST', 'PUT', 'PATCH', 'GET', 'HEAD']) {
        const body = ['GET', 'HEAD'].includes(method) ? undefined : 'payload';
        const response = await fetch(`http://127.0.0.1:${server.address().port}/redirect/${status}`, { method, body });
        await response.arrayBuffer();
        rows.push({ status, method, ...{ expectedMethod: server.lastRequest.method, expectedBody: server.lastRequest.body } });
      }
    }
    const streaming = [];
    for (const status of [301, 302, 303, 307, 308]) {
      for (const body of ['', 'payload']) {
        try {
          const response = await fetch(`http://127.0.0.1:${server.address().port}/redirect/${status}`, {
            method: 'POST', duplex: 'half', body: new ReadableStream({start(controller) {
              if (body) controller.enqueue(new TextEncoder().encode(body));
              controller.close();
            }}),
          });
          await response.arrayBuffer();
          streaming.push({status, body, rejected: false, expectedMethod: server.lastRequest.method});
        } catch (_) { streaming.push({status, body, rejected: true}); }
      }
    }
    fs.writeFileSync('test/http_redirect_stream_vectors.json', JSON.stringify(streaming, null, 2) + '\n');
    fs.writeFileSync('test/http_redirect_vectors.json', JSON.stringify(rows, null, 2) + '\n');
    console.log(`${rows.length} buffered + ${streaming.length} streaming Node fetch redirect vectors`);
  } finally {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
