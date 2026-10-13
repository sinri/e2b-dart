#!/usr/bin/env python3
"""Report lexical input dependencies in the pinned pure-Dart Brotli candidate.

This inventories migration scope; it does not prove streaming correctness.
Usage: python3 tool/audit_brotli_candidate.py /path/to/brotli-0.6.0
"""
import argparse
import hashlib
import json
import re
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('candidate', type=Path)
args = parser.parse_args()
path = args.candidate / 'lib/src/decoder/decode.dart'
source = path.read_text()
core = source.split('/// An instance of the default', 1)[0]
functions = list(re.finditer(r'^(?:void|int|List<int>)\s+(_\w+)\s*\(', core, re.M))
calls = {}
for index, match in enumerate(functions):
    end = functions[index + 1].start() if index + 1 < len(functions) else len(core)
    calls[match[1]] = set(re.findall(r'(_\w+)\s*\(', core[match.end():end]))
affected = {'_readInput'}
while True:
    expanded = affected | {name for name, refs in calls.items() if refs & affected}
    if expanded == affected:
        break
    affected = expanded
print(json.dumps({
    'source_sha256': hashlib.sha256(source.encode()).hexdigest(),
    'source_lines': len(source.splitlines()),
    'lexically_detected_core_functions': len(calls),
    'input_dependent_functions': sorted(affected),
    'scope': 'lexical call inventory, excludes methods and dynamic calls',
    'streaming_proven': False,
}, indent=2))
