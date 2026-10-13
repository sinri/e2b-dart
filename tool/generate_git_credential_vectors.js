// WHATWG URL setters are the official JS implementation's credential encoder.
const fs = require('node:fs');
const inputs = Array.from({length: 128}, (_, i) => String.fromCharCode(i));
inputs.push('ü😀', '\ud800', '\udc00', '%2F%25', 'user:name@example.test');
const rows = inputs.map(input => {
  const url = new URL('https://example.test/repo');
  url.username = input;
  url.password = input;
  return {input, encoded: url.username};
});
fs.writeFileSync('test/git_credential_vectors.json', JSON.stringify(rows, null, 2) + '\n');
