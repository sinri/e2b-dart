"""Record public method candidates from the pinned official source checkout.

Usage: python3 tool/inventory_upstream.py /tmp/e2b-upstream
This inventory does not prove behavioral parity. Preserve audited statuses when
regenerating; exported types, getters, overloads and runtime behavior are audited
separately in docs/PARITY.md.
"""
import json
import pathlib
import re
import subprocess
import sys

checkout = pathlib.Path(sys.argv[1])
root = checkout / 'packages/js-sdk/src'
commit = subprocess.check_output(['git', '-C', str(checkout), 'rev-parse', 'HEAD'], text=True).strip()
expected = 'df6c368152b067512702fc677952c0fc4e13c2f0'
if commit != expected:
    raise SystemExit(f'Expected {expected}, got {commit}; review baseline before regenerating')
output = pathlib.Path('docs/parity.json')
previous = json.loads(output.read_text()) if output.exists() else {}
known = {item['symbol']: item for item in previous.get('methods', [])}
files = ['client.ts', 'connectionConfig.ts', 'secret.ts', 'sandbox/index.ts',
         'sandbox/sandboxApi.ts', 'sandbox/commands/index.ts',
         'sandbox/commands/commandHandle.ts', 'sandbox/commands/pty.ts',
         'sandbox/filesystem/index.ts', 'sandbox/filesystem/watchHandle.ts',
         'sandbox/git/index.ts', 'volume/index.ts', 'template/index.ts',
         'template/readycmd.ts', 'template/logger.ts']
rows = {}
for name in files:
    inside_class = False
    for n, line in enumerate((root / name).read_text().splitlines(), 1):
        if re.match(r'(?:export )?(?:abstract )?class \w+', line):
            inside_class = True
        if line == '}':
            inside_class = False
        match = re.match(r'  (?:(static) )?(?:async )?(\w+)\(', line)
        if not inside_class or not match or match[2] == 'constructor':
            continue
        symbol = f'{name}:{"static " if match[1] else ""}{match[2]}'
        if symbol not in rows:
            rows[symbol] = {**known.get(symbol, {'symbol': symbol, 'status': 'pending', 'dart': None, 'evidence': []}), 'upstreamLine': n}
output.write_text(json.dumps({
    'upstream': {'package': 'e2b', 'version': '2.55.0', 'commit': commit},
    'policy': 'Public method candidates only. Overloads collapsed; getters, exported types and top-level functions are audited separately. implemented means code exists, not that full equivalence is proven. See PARITY.md.',
    'methods': list(rows.values()),
}, ensure_ascii=False, indent=2) + '\n')
print(f'{len(rows)} method candidates saved')
