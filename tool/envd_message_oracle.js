// Execute the pinned official extractor body without loading SDK dependencies.
const fs = require('node:fs');
const path = require('node:path');
const root = process.argv[2];
const source = fs.readFileSync(path.join(root, 'packages/js-sdk/src/envd/api.ts'), 'utf8');
const start = source.indexOf('  let message =', source.indexOf('export async function getEnvdApiErrorMessage'));
const end = source.indexOf('\n}', start);
if (start < 0 || end < 0) throw Error('extractor not found');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const extract = new AsyncFunction('res', source.slice(start, end));
(async () => {
  const vectors = [];
  for (const value of [null, false, true, 0, 1, -1, 1e21, '', 'detail', [], [null, 1, {}], {}, {a: 1}]) {
    const response = new Response(JSON.stringify({message: value}), {status: 400, statusText: 'Fallback'});
    const error = await response.json();
    const result = await extract({error, response});
    vectors.push({body: error, expected: new Error(result).message});
  }
  fs.writeFileSync('test/envd_message_vectors.json', JSON.stringify({node: process.version, vectors}, null, 2) + '\n');
})();
