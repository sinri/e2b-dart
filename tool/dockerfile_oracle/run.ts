import {parseDockerfile} from './parser.ts';
import fs from 'node:fs';
const fixtures=JSON.parse(fs.readFileSync(0,'utf8'));
for(const fixture of fixtures){
 const data:any={steps:[],force:false};
 const b:any={setUser(x:string){data.steps.push({type:'USER',args:[x],force:false});return b},setWorkdir(x:string){data.steps.push({type:'WORKDIR',args:[x],force:false});return b},setEnvs(x:any){if(Object.keys(x).length)data.steps.push({type:'ENV',args:Object.entries(x).flat(),force:false});return b},runCmd(x:string,o:any){data.steps.push({type:'RUN',args:[x,...(o?.user?[o.user]:[])],force:false});return b},copy(x:string,d:string,o:any){data.steps.push({type:'COPY',args:[x,d,o?.user??'',o?.mode===undefined?'':o.mode.toString(8).padStart(4,'0')],force:false});return b},setStartCmd(x:string,r:any){data.startCmd=x;data.readyCmd=r.getCmd();return b}};
 try{data.fromImage=parseDockerfile(fixture.input,b).baseImage;fixture.expected=data;}catch(e){fixture.error=String(e)}
}
console.log(JSON.stringify(fixtures,null,2));
