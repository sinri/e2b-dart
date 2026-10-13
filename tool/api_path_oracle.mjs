import fs from 'node:fs';
import {pathToFileURL} from 'node:url';
const {default: createClient} = await import(pathToFileURL(process.argv[2]));
const vectors = [];
for (const token of ['{id}', '{id*}', '{.id}', '{.id*}', '{;id}', '{;id*}']) {
 for (const value of [null, '', 0, false, '世界 /?#', [], ['a,b', 'x y', null], {}, {a:1,b:'x y',nil:null}, {'10':'ten','2':'two'}, {nested:[1,2]}]) {
  const row = {path:`/test/${token}/${token}`, parameters:{id:value}};
  const client = createClient({baseUrl:'https://example.test', fetch:async request=>{row.url=request.url;return new Response('{}');}});
  try {await client.GET(row.path,{params:{path:row.parameters}});} catch(error) {row.error=error.message;}
  vectors.push(row);
 }
}
fs.writeFileSync('test/api_path_vectors.json',JSON.stringify({version:'openapi-fetch 0.17.0',vectors},null,2)+'\n');
