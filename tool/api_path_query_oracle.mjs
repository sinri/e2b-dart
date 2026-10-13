import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';

// Pass the pinned openapi-fetch 0.17.0 module path.
const {default: createClient} = await import(pathToFileURL(process.argv[2]));
const urls = [];
const client = createClient({
  baseUrl: 'https://bound.test/base/',
  fetch: async request => {
    urls.push(request.url);
    return new Response('{}');
  },
});
for (const suffix of ['x?kept=1', 'x#fragment', 'x?kept=1#fragment']) {
  await client.GET('/items/{id}', {
    params: {path: {id: 'x'}, query: {a: 'b'}},
    pathSerializer: url => url.replace('{id}', suffix),
  });
}
assert.deepEqual(urls, [
  'https://bound.test/base/items/x?kept=1?a=b',
  'https://bound.test/base/items/x#fragment?a=b',
  'https://bound.test/base/items/x?kept=1#fragment?a=b',
]);
console.log('openapi-fetch 0.17.0: 3 path/query combinations passed');
