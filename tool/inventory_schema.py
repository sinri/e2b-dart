"""Inventory the pinned generated management schema; this is not a port verifier."""
import hashlib
import json
import pathlib
import re
import subprocess
import sys

checkout = pathlib.Path(sys.argv[1])
commit = subprocess.check_output(
    ['git', '-C', str(checkout), 'rev-parse', 'HEAD'], text=True).strip()
if commit != 'df6c368152b067512702fc677952c0fc4e13c2f0':
    raise SystemExit(f'Unexpected upstream commit: {commit}')
source = checkout / 'packages/js-sdk/src/api/schema.gen.ts'
text = source.read_text()
paths_text, components_text = text.split('export interface components {', 1)
paths = []
for match in re.finditer(r'^    "([^"]+)": \{', paths_text, re.M):
    end = paths_text.find('\n    };', match.end())
    block = paths_text[match.end():end]
    methods = re.findall(r'^        (get|put|post|delete|options|head|patch|trace): (?!never)', block, re.M)
    paths.append({'path': match[1], 'methods': methods})
schemas_text = components_text.split('    schemas: {', 1)[1].split('\n    responses:', 1)[0]
schemas = re.findall(r'^        (\w+):', schemas_text, re.M)
data = {
    'upstream': 'e2b 2.55.0',
    'commit': commit,
    'sourceSha256': hashlib.sha256(source.read_bytes()).hexdigest(),
    'policy': 'Source inventory only; no generated Dart typing or behavioral parity inferred.',
    'paths': paths,
    'schemas': schemas,
}
rendered = json.dumps(data, indent=2) + '\n'
output = pathlib.Path('docs/schema_inventory.json')
if '--check' in sys.argv:
    if output.read_text() != rendered:
        raise SystemExit('Schema inventory differs')
else:
    output.write_text(rendered)
print(f'{len(paths)} paths, {sum(len(p["methods"]) for p in paths)} operations, {len(schemas)} schemas')
