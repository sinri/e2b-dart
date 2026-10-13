import fs from 'node:fs';
import { pathToFileURL } from 'node:url';
const { default: createClient } = await import(pathToFileURL(process.argv[2]));
const vectors = [];
for (const status of [200, 400, 304, 204]) {
  for (const method of ['GET', 'HEAD']) {
    for (const parseAs of ['json', 'text', 'arrayBuffer']) {
      for (const body of status === 304 || status === 204 ? [''] : ['', 'plain', '{"a":1}']) {
        const headers = {'content-type': 'application/json'};
        const client = createClient({baseUrl: 'https://example.test', fetch: async () =>
          new Response(status === 304 || status === 204 ? null : body, {status, headers})});
        const row = {status, method, parseAs, body, headers};
        try {
          const result = await client.request(method, '/test', {parseAs});
          const value = status >= 200 && status < 300 ? result.data : result.error;
          row.kind = value === undefined ? 'undefined' : value instanceof ArrayBuffer ? 'bytes' : 'value';
          if (row.kind !== 'undefined') row.expected = value instanceof ArrayBuffer ? [...new Uint8Array(value)] : value;
        } catch (error) { row.kind = 'throws'; row.error = error.name; }
        vectors.push(row);
      }
    }
  }
}
fs.writeFileSync('test/api_parse_vectors.json', JSON.stringify({version:'openapi-fetch 0.17.0', node:process.version, vectors}, null, 2)+'\n');
