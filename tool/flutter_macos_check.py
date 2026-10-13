"""Build the SDK Flutter example in a fresh macOS runner.
Usage: python3 tool/flutter_macos_check.py /path/to/flutter [--network-check]
Requires macOS/Xcode; leaves the generated project in a printed temp directory.
No cloud credentials are used or embedded.
"""
import platform
import pathlib
import plistlib
import subprocess
import sys
import tempfile

workspace = pathlib.Path(__file__).resolve().parent.parent
project = pathlib.Path(tempfile.mkdtemp(prefix='e2b-macos-check-')) / 'app'
flutter = sys.argv[1]
subprocess.run([flutter, 'create', '--platforms=macos', '--project-name',
                'e2b_desktop_check', '--no-pub', str(project)], check=True)
pubspec = project / 'pubspec.yaml'
pubspec.write_text(pubspec.read_text().replace(
    'dependencies:\n', f'dependencies:\n  e2b:\n    path: {workspace.as_posix()}\n', 1))
network = '--network-check' in sys.argv[2:]
entry = 'network_check.dart' if network else 'main.dart'
(project / 'lib/main.dart').write_text((workspace / 'example/flutter/lib' / entry).read_text())
for name in ['DebugProfile.entitlements', 'Release.entitlements']:
    path = project / 'macos/Runner' / name
    values = plistlib.loads(path.read_bytes())
    values['com.apple.security.network.client'] = True
    path.write_bytes(plistlib.dumps(values))
# Xcode 27 rejects Flutter's generated 10.15 deployment target.
path = project / 'macos/Runner.xcodeproj/project.pbxproj'
path.write_text(path.read_text().replace(
    'MACOSX_DEPLOYMENT_TARGET = 10.15;',
    f'MACOSX_DEPLOYMENT_TARGET = 12.0;\n                ARCHS = {platform.machine()};'))
print(f'Generated project: {project}', flush=True)
subprocess.run([flutter, 'pub', 'get'], cwd=project, check=True)
subprocess.run([flutter, 'build', 'macos', '--release', '--no-pub'], cwd=project, check=True)

if network:
    executable = project / 'build/macos/Build/Products/Release/e2b_desktop_check.app/Contents/MacOS/e2b_desktop_check'
    subprocess.run([sys.executable, str(workspace / 'tool/macos_network_peer.py'), str(executable)], check=True)
