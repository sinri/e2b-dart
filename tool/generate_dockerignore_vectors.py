"""Extract fixed upstream Moby patternmatcher test tables using Node >=22.21."""
from pathlib import Path
import json
import subprocess
import sys
import tempfile
upstream = Path(sys.argv[1]).resolve()
revision = subprocess.check_output(['git','-C',str(upstream),'rev-parse','HEAD'],text=True).strip()
assert revision == 'df6c368152b067512702fc677952c0fc4e13c2f0'
source = (upstream/'packages/dockerfile-utils-js/tests/moby-patternmatcher.test.ts').read_text()
source = source[source.index('// [pattern, text, pass]'):source.index("describe('moby/patternmatcher'")]
source += '\nconsole.log(JSON.stringify({matchesTests,multiPatternTests,matchTests}, null, 2));\n'
with tempfile.TemporaryDirectory(prefix='e2b-ignore-oracle-') as directory:
    script = Path(directory)/'vectors.ts'
    script.write_text(source)
    result = subprocess.check_output(['node','--no-warnings','--experimental-transform-types',str(script)],text=True)
    target = Path(__file__).resolve().parent.parent/'test/dockerignore_vectors.json'
    target.write_text(result)
    tables = json.loads(result)
    print({k:len(v) for k,v in tables.items()})
