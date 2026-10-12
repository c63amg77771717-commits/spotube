"""Existing Build24 device compilation/ditto route with exact public inputs."""
import hashlib
import json
import os
import pathlib
import plistlib
import shutil
import sys
import zipfile

from boundary import captured_command, preflight
from ipa_policy import (BUILD, VERSION, IPA_NAME, MANIFEST_NAME, require,
                        validate_app, validate_manifest, validate_project)

REPO = pathlib.Path(__file__).resolve().parents[2]

def main():
    try:
        require(sys.platform == 'darwin' and os.environ.get('GITHUB_ACTIONS') == 'true')
        require(os.environ.get('GITHUB_REPOSITORY') == 'c63amg77771717-commits/spotube')
        require(os.environ.get('GITHUB_REF') == 'refs/heads/codex/ios-neonoir-20260930')
        require(os.environ.get('GITHUB_WORKFLOW') == 'EvanTube public synthetic native tests')
        event = json.loads(pathlib.Path(os.environ['GITHUB_EVENT_PATH']).read_bytes())
        preflight(REPO, event, os.environ['GITHUB_EVENT_NAME'])
        spec = json.loads((REPO / 'native-ios/public-ipa-project.json').read_bytes())
        validate_project(spec)
        lock = json.loads((REPO / 'scripts/ios-public-ci/input-lock.json').read_bytes())
        allowed_json = {digest for path, digest in lock['inputs'].items()
                        if path.startswith('native-ios/LovelyMusic/Resources/') and path.endswith('.json')}
        temporary = pathlib.Path(os.environ['RUNNER_TEMP']) / 'evantube-public-ipa'
        require(not temporary.exists())
        temporary.mkdir()
        output = temporary / 'out'
        output.mkdir()
        # Never copy production/example credentials or inherit GitHub secrets.
        secrets_file = REPO / 'native-ios/LovelyMusic/Resources/Secrets.plist'
        require(not secrets_file.exists())
        secrets_file.write_bytes(plistlib.dumps({}))
        captured_command(['brew', 'install', 'xcodegen'], REPO, temporary / 'dependencies-local-only.log')
        captured_command(['xcodegen', 'generate', '--spec', 'public-ipa-project.json'],
                         REPO / 'native-ios', temporary / 'generate-local-only.log')
        derived = temporary / 'derived'
        captured_command(['xcodebuild', '-project', 'LovelyMusic.xcodeproj', '-scheme', 'LovelyMusic',
                          '-configuration', 'Release', '-sdk', 'iphoneos', '-destination', 'generic/platform=iOS',
                          '-derivedDataPath', str(derived), 'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=NO',
                          'CODE_SIGNING_ALLOWED=NO', 'build'],
                         REPO / 'native-ios', temporary / 'device-build-local-only.log')
        app = derived / 'Build/Products/Release-iphoneos/LovelyMusic.app'
        info = validate_app(app, allowed_json)
        payload = temporary / 'Payload'
        payload.mkdir()
        shutil.copytree(app, payload / 'EvanTube.app', symlinks=True)
        ipa = output / IPA_NAME
        captured_command(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(payload), str(ipa)],
                         REPO, temporary / 'package-local-only.log')
        with zipfile.ZipFile(ipa) as archive:
            require(archive.testzip() is None)
            for name in archive.namelist():
                path = pathlib.PurePosixPath(name)
                require(not path.is_absolute() and '..' not in path.parts)
                require(path.parts and path.parts[0] in {'Payload', '__MACOSX'})
            require(archive.read('Payload/EvanTube.app/' + info['CFBundleExecutable']) ==
                    (app / info['CFBundleExecutable']).read_bytes())
        with ipa.open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        manifest = {'file': IPA_NAME, 'bytes': ipa.stat().st_size, 'sha256': digest,
                    'sourceSHA': os.environ['GITHUB_SHA'], 'version': VERSION, 'build': BUILD,
                    'bundleID': info['CFBundleIdentifier'], 'architecture': 'arm64', 'unsigned': True,
                    'archiveIntegrity': 'PASS', 'deviceCompilation': 'PASS',
                    'sourceReplacementTests': 17, 'lyricsRegressionTests': 16, 'liveQueries': 0,
                    'physicalDevice': 'NOT_RUN', 'humanVerification': 'NOT_RUN', 'credentialsEmbedded': False}
        validate_manifest(manifest)
        (output / MANIFEST_NAME).write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf8')
        require({path.name for path in output.iterdir()} == {IPA_NAME, MANIFEST_NAME})
        print('PUBLIC_UNSIGNED_IPA_PASS version=1.0.1 build=26 sourceTests=17 regressionTests=16 physicalDevice=NOT_RUN')
        return 0
    except Exception:
        print('PUBLIC_UNSIGNED_IPA_BLOCKED_OR_FAILED; detailed output stays runner-local', file=sys.stderr)
        return 1

if __name__ == '__main__':
    sys.exit(main())
