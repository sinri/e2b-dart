"""Inventory named top-level exports of the pinned E2B source entry point.

Usage: python3 tool/inventory_exports.py /tmp/e2b-upstream [--check]
This records export statements, not member/overload/behavior completeness.
"""
import json
import pathlib
import re
import subprocess
import sys

checkout = pathlib.Path(sys.argv[1])
root = (checkout / 'packages/js-sdk/src').resolve()
expected = 'df6c368152b067512702fc677952c0fc4e13c2f0'
commit = subprocess.check_output(
    ['git', '-C', str(checkout), 'rev-parse', 'HEAD'], text=True).strip()
if commit != expected:
    raise SystemExit(f'Expected {expected}, got {commit}')
output = pathlib.Path('docs/exports.json')
old = json.loads(output.read_text()) if output.exists() else {}
known = {row['name']: row for row in old.get('exports', [])}
rows = {}
visited = set()
pattern = re.compile(
    r'^export\s+(?:(type)\s+)?\{([^}]+)\}(?:\s+from\s+[\'"]([^\'"]+)[\'"])?'
    r'|^export\s+\*\s+from\s+[\'"]([^\'"]+)[\'"]'
    r'|^export\s+(?:declare\s+)?(class|interface|type|enum|const|function)\s+(\w+)'
    r'|^export\s+default\s+(\w+)', re.MULTILINE)


def resolve(file, module):
    base = file.parent / module
    for candidate in [base.with_suffix('.ts'), base.with_suffix('.d.ts'), base / 'index.ts']:
        if candidate.exists():
            return candidate.resolve()
    raise ValueError(f'Cannot resolve {module} from {file}')


def visit(file):
    if file in visited:
        return
    visited.add(file)
    text = file.read_text()
    for match in pattern.finditer(text):
        line = text.count('\n', 0, match.start()) + 1
        source = str(file.relative_to(root))
        type_only, members, module, wildcard, kind, declaration, default = match.groups()
        if wildcard:
            visit(resolve(file, wildcard))
            continue
        entries = []
        if members:
            for member in re.sub(r'//[^\n]*', '', members).split(','):
                member = member.strip()
                if not member:
                    continue
                local_type = member.startswith('type ')
                member = re.sub(r'^type\s+', '', member)
                parts = re.split(r'\s+as\s+', member)
                entries.append((parts[-1], parts[0], 'type' if type_only or local_type else 'value', module))
        elif declaration:
            entries.append((declaration, declaration,
                            'type' if kind in ('interface', 'type') else 'value', None))
        elif default:
            entries.append(('default', default, 'value', None))
        for name, original, category, module in entries:
            if name in rows:
                raise ValueError(f'Duplicate export: {name}')
            previous = known.get(name, {})
            rows[name] = {
                'name': name, 'original': original, 'category': category,
                'entrySource': source, 'upstreamLine': line, 'module': module,
                'status': previous.get('status', 'pending_audit'),
                'dart': previous.get('dart'), 'evidence': previous.get('evidence', []),
                'notes': previous.get('notes', ''),
            }


visit(root / 'index.ts')
data = {
    'upstream': {'package': 'e2b', 'version': '2.55.0', 'commit': commit},
    'policy': 'Named entry-point exports including wildcard template exports. '
              'Type-only exports remain distinct from values. No member, overload, '
              'platform or behavioral parity is inferred. All mappings require audit.',
    'exports': sorted(rows.values(), key=lambda row: row['name']),
}
# Evidence references must identify real workspace files. Existence is a
# necessary integrity check, never proof of behavioral completeness.
for row in data['exports']:
    references = list(row['evidence'])
    if row['dart'] is not None:
        references.append(row['dart']['file'])
    for reference in references:
        if not pathlib.Path(reference).is_file():
            raise SystemExit(f"{row['name']}: missing reference file {reference}")

rendered = json.dumps(data, ensure_ascii=False, indent=2) + '\n'
if '--check' in sys.argv:
    if not output.exists() or output.read_text() != rendered:
        raise SystemExit('Export inventory differs; regenerate and review')
else:
    output.write_text(rendered)
print(f'{len(rows)} entry exports ({sum(r["category"] == "type" for r in rows.values())} type-only)')
