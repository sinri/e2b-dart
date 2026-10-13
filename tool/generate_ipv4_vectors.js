const fs = require('node:fs');
let state = 0x12345678;
const next = () => { state ^= state << 13; state ^= state >>> 17; state ^= state << 5; return state >>> 0; };
const hosts = ['0x','0','09','1.2.3.4.5','a.1','example.test','[::1]', '1..2', '.1', '.', '..', '0x.1', '1.0x'];
for (let i = 0; i < 1024; i++) {
  const count = 1 + next() % 5;
  const parts = Array.from({length: count}, () => {
    const n = next() % 70000;
    switch(next() % 3) {
      case 0: return n.toString();
      case 1: return '0x' + n.toString(16);
      default: return '0' + n.toString(8);
    }
  });
  hosts.push(parts.join('.') + (next() % 4 === 0 ? '.' : ''));
}
const rows = hosts.map(input => {
  try { return {input, host: new URL('https://' + input + '/').hostname}; }
  catch { return {input, host: null}; }
});
fs.writeFileSync('test/ipv4_vectors.json', JSON.stringify(rows, null, 2) + '\n');
