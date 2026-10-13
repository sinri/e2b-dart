"""Regenerate focused official converter vectors using Node >=22.21.
Usage: python3 tool/generate_dockerfile_vectors.py /path/to/E2B
Adapters replace only imports and the template builder sink; parsing/conversion
runs from the pinned upstream TypeScript sources, not a reimplementation.
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

upstream = Path(sys.argv[1]).resolve()
revision = subprocess.check_output(['git', '-C', str(upstream), 'rev-parse', 'HEAD'], text=True).strip()
assert revision == 'df6c368152b067512702fc677952c0fc4e13c2f0', revision
root = Path(__file__).resolve().parent.parent
vectors_path = root / 'test/dockerfile_vectors.json'
inputs = [{'input': v['input']} for v in json.loads(vectors_path.read_text())]
with tempfile.TemporaryDirectory(prefix='e2b-dockerfile-oracle-') as directory:
    target = Path(directory)
    for name in ['lexer', 'syntax', 'dockerignore', 'index']:
        source = (upstream / f'packages/dockerfile-utils-js/src/{name}.ts').read_text()
        for dependency in ['lexer', 'syntax', 'dockerignore']:
            source = source.replace(f"'./{dependency}'", f"'./{dependency}.ts'")
        (target / f'{name}.ts').write_text(source)
    parser = (upstream / 'packages/js-sdk/src/template/dockerfileParser.ts').read_text()
    parser = parser.replace("from '../utils'", "from './helpers.ts'")
    parser = parser.replace("import { CopyItem } from './types'", 'type CopyItem = any')
    parser = parser.replace("from './readycmd'", "from './helpers.ts'")
    parser = parser.replace("from '@e2b/dockerfile-utils'", "from './index.ts'")
    parser = parser.replace('  DockerfileHeredoc,\n', '').replace('  DockerfileInstruction,\n', '')
    parser = "import type { DockerfileHeredoc, DockerfileInstruction } from './index.ts'\n" + parser
    (target / 'parser.ts').write_text(parser)
    for name in ['helpers', 'run']:
        (target / f'{name}.ts').write_text((root / f'tool/dockerfile_oracle/{name}.ts').read_text())
    result = subprocess.run(['node', '--no-warnings', '--experimental-transform-types', str(target / 'run.ts')],
                            input=json.dumps(inputs), text=True, capture_output=True, check=True)
    vectors_path.write_text(result.stdout)
