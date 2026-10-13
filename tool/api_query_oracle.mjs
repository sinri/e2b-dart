import fs from 'node:fs';
import {pathToFileURL} from 'node:url';
const {default: createClient} = await import(pathToFileURL(process.argv[2]));
const inputs = [
 {}, {empty: [], nil: null, value: ''}, {state: ['running','paused']},
 {a: ['a,b', 'a b', 'x&y', null, false, 0]}, {a: [[],[1,2],{}]},
 {obj: {a: 1, b: 'a b', nil: null, empty: ''}}, {obj: {}},
 {before: 1, obj: {}, after: 2}, {obj: {nested: {a: 1}}},
 {obj: {nested: [1,2]}}, {'a b': '世界!*\'()', '世界': '/?#&='},
 {'10': 'ten', '2': 'two', '01': 'zero-one', name: true},
 {obj: {'10': 'ten', '2': 'two', '01': 'zero-one'}},
];
const vectors = [];
for (const query of inputs) {
 const row = {query};
 const client = createClient({baseUrl:'https://example.test', querySerializer:{array:{style:'form',explode:false}},
   fetch: async request => {row.url = request.url; return new Response('{}');}});
 try {await client.GET('/test', {params:{query}});} catch(error) {row.error = error.message;}
 vectors.push(row);
}
fs.writeFileSync('test/api_query_vectors.json', JSON.stringify({version:'openapi-fetch 0.17.0',vectors},null,2)+'\n');
