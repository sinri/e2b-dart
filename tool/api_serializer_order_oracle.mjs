import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';

const {default: createClient} = await import(pathToFileURL(process.argv[2]));
for (const failAt of ['', 'body', 'path', 'query']) {
  const events = [];
  const record = (name, result) => {
    events.push(name);
    if (name === failAt) throw new Error(name);
    return result;
  };
  const client = createClient({
    baseUrl: 'https://example.test',
    fetch: async () => {
      events.push('fetch');
      return new Response('{}');
    },
  });
  let failure;
  try {
    await client.POST('/test', {
      body: {x: 1}, params: {path: {}},
      bodySerializer: () => record('body', '{}'),
      pathSerializer: url => record('path', url),
      querySerializer: () => record('query', 'a=b'),
    });
  } catch (error) { failure = error; }
  const order = ['body', 'path', 'query', 'fetch'];
  assert.deepEqual(events, failAt ? order.slice(0, order.indexOf(failAt) + 1) : order);
  assert.equal(failure?.message ?? '', failAt);
}
console.log('openapi-fetch 0.17.0: serializer order and 3 failure cases passed');
