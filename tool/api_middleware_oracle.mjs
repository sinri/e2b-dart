import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';
const {default: createClient} = await import(pathToFileURL(process.argv[2]));
for (const mode of ['normal', 'short', 'error']) {
  const events = [];
  const client = createClient({baseUrl:'https://example.test', fetch:async () => {
    events.push('fetch');
    if (mode === 'error') throw new Error('network');
    return new Response('{}');
  }});
  client.use({onRequest:() => {events.push('global-request');},
    onError:() => {events.push('global-error'); return new Response('{}');},
    onResponse:() => {events.push('global-response');}});
  await client.GET('/test', {middleware:[{
    onRequest:() => {events.push('local-request'); if (mode === 'short') return new Response('{}');},
    onError:() => {events.push('local-error'); return new Error('replaced');},
    onResponse:() => {events.push('local-response');},
  }]});
  const expected = ['global-request','local-request'];
  if (mode !== 'short') {
    expected.push('fetch');
    if (mode === 'error') expected.push('local-error','global-error');
    expected.push('local-response','global-response');
  }
  assert.deepEqual(events, expected);
}
console.log('openapi-fetch 0.17.0: normal, short-circuit and recovered error hook order passed');
