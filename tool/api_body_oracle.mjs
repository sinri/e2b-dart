import fs from 'node:fs';
import {pathToFileURL} from 'node:url';
const {default:createClient} = await import(pathToFileURL(process.argv[2]));
const vectors=[];
for(const body of [{a:'hello world',b:'!*\'()~'},{a:null,b:false,c:[1,null,2],d:{x:1}},{'10':'ten','2':'two','01':'one',unicode:'中文'}, [['a',1],['a',2],['nil',null],['array',[1,2]]], '?a=one+two&a=three&empty&x=a=b', '&&a=%FF&b=%ZZ&c=%EF%BB%BF&d=%E2%82', '', '?', [['a']], [['a',1,2]]]) {
 const row={body};
 const client=createClient({baseUrl:'https://example.test',fetch:async request=>{row.text=await request.text();return new Response('{}')}});
 try {await client.POST('/test',{body,headers:{'content-type':'application/x-www-form-urlencoded'}});} catch(error) {row.error=error.message;}
 vectors.push(row);
}
fs.writeFileSync('test/api_body_vectors.json',JSON.stringify({version:'openapi-fetch 0.17.0',vectors},null,2)+'\n');
