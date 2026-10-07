"""Package a compiled device app with explicit NOT-RUN acceptance evidence."""
import argparse
import hashlib
import json
import pathlib
import plistlib
import shutil
import struct
import subprocess
import tempfile
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument('--app', type=pathlib.Path, required=True)
parser.add_argument('--output', type=pathlib.Path, required=True)
parser.add_argument('--receipt', type=pathlib.Path, required=True)
parser.add_argument('--build', required=True)
parser.add_argument('--source-sha', required=True)
args = parser.parse_args()
assert args.app.is_dir() and not args.output.exists()
info = plistlib.loads((args.app / 'Info.plist').read_bytes())
assert info['CFBundleVersion'] == args.build
assert info['CFBundleShortVersionString'] == '1.0.0'
assert info['CFBundleIdentifier'] == 'com.c63amg77771717.evantube'
binary = (args.app / info['CFBundleExecutable']).read_bytes()
header = struct.unpack_from('<8I', binary)
assert header[0] == 0xfeedfacf and header[1] == 0x0100000c, 'Expected thin arm64 device Mach-O'
offset = 32
for _ in range(header[4]):
    command, size = struct.unpack_from('<II', binary, offset)
    assert size >= 8 and offset + size <= len(binary)
    if command == 0x1d:
        assert struct.unpack_from('<IIII', binary, offset)[3] == 0, 'Main executable is signed'
    offset += size
assert not list(args.app.rglob('embedded.mobileprovision'))
assert not list(args.app.rglob('_CodeSignature')), 'Expected unsigned bundle and extensions'
extensions = [plistlib.loads(path.read_bytes()) for path in args.app.glob('PlugIns/*.appex/Info.plist')]
assert extensions and all(value['CFBundleVersion'] == args.build for value in extensions)
args.output.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='evantube-test-ipa-') as temp:
    payload = pathlib.Path(temp) / 'Payload'
    payload.mkdir()
    shutil.copytree(args.app, payload / 'EvanTube.app', symlinks=True)
    subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(payload), str(args.output.resolve())], check=True)
with zipfile.ZipFile(args.output) as archive:
    assert archive.testzip() is None
    assert archive.read('Payload/EvanTube.app/' + info['CFBundleExecutable']) == binary
receipt = {'file': args.output.name, 'bytes': args.output.stat().st_size,
    'sha256': hashlib.file_digest(args.output.open('rb'), 'sha256').hexdigest(),
    'sourceSHA': args.source_sha, 'build': args.build, 'version': info['CFBundleShortVersionString'],
    'bundleID': info['CFBundleIdentifier'], 'architecture': 'arm64', 'unsigned': True,
    'archiveIntegrity': 'PASS', 'extensionBuilds': [value['CFBundleVersion'] for value in extensions],
    'deviceCompilation': 'PASS', 'testOnly': True, 'formalPrepackageGate': 'NOT_RUN',
    'fortySongAcceptance': 'NOT_RUN', 'nativeAndUIAcceptance': 'NOT_RUN',
    'actualVocalAlignment': 'NOT_RUN', 'physicalDeviceAcceptance': 'NOT_RUN'}
args.receipt.parent.mkdir(parents=True, exist_ok=True)
args.receipt.write_text(json.dumps(receipt, indent=2), encoding='utf-8')
print(json.dumps(receipt, indent=2))
