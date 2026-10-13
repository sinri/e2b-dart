export function shellQuote(s:string){return s === '' ? "''" : /^[a-zA-Z0-9_@%+=:,./-]+$/.test(s) ? s : "'"+s.replaceAll("'", "'\"'\"'")+"'"}
export class ReadyCmd {constructor(public cmd:string){} getCmd(){return this.cmd}}
export function waitForTimeout(ms:number){return new ReadyCmd('sleep '+Math.max(1,Math.floor(ms/1000)))}
