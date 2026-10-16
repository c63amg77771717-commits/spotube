"""Synthetic offline package policy checks; only aggregate output is public."""
import contextlib
import copy
import io
import json
import pathlib
import plistlib
import struct
import sys
import tempfile
import unittest

from ipa_policy import (BUILD, VERSION, IPA_NAME, EXPECTED_MAIN, EXPECTED_CHILD, PolicyBlocked,
                        validate_app, validate_manifest, validate_macho, validate_project,
                        validate_workflow_values, validate_workflows, validate_no_lyrics_application, validate_verification_recovery)

REPO = pathlib.Path(__file__).resolve().parents[2]
CANARY = 'SYNTHETIC_PRIVATE_CANARY_NO_REAL_SONG_OR_CREDENTIAL'

def macho(platform=2, signature_size=0):
    commands = struct.pack('<6I', 0x32, 24, platform, 0, 0, 0)
    commands += struct.pack('<4I', 0x1d, 16, 0, signature_size)
    return struct.pack('<8I', 0xfeedfacf, 0x0100000c, 0, 2, 2, len(commands), 0, 0) + commands

def app_fixture(folder):
    app = pathlib.Path(folder) / 'Synthetic.app'
    extension = app / 'PlugIns/Synthetic.appex'
    extension.mkdir(parents=True)
    for path, identifier in [(app, 'com.c63amg77771717.evantube'),
                             (extension, 'com.c63amg77771717.evantube.NotificationService')]:
        (path / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleVersion': BUILD, 'CFBundleShortVersionString': VERSION,
            'CFBundleIdentifier': identifier, 'CFBundleExecutable': 'SyntheticBinary'}))
        (path / 'SyntheticBinary').write_bytes(macho())
    (app / 'Secrets.plist').write_bytes(plistlib.dumps({}))
    return app

class IPAPolicyTests(unittest.TestCase):
    def blocked_safely(self, action):
        stream = io.StringIO()
        with contextlib.redirect_stdout(stream), contextlib.redirect_stderr(stream):
            with self.assertRaises(PolicyBlocked) as caught:
                action()
        self.assertNotIn(CANARY, stream.getvalue() + str(caught.exception))

    def test_exact_workflows_and_same_commit_test_dependency(self):
        validate_workflows(REPO)
        self.assertEqual(EXPECTED_MAIN['jobs']['unsigned_ipa']['needs'], 'public_synthetic_validation')
        self.assertNotIn('secrets', EXPECTED_MAIN['jobs']['unsigned_ipa'])
        self.assertEqual(EXPECTED_CHILD['on'], {'workflow_call': {}})
        self.assertNotIn('upload-artifact', json.dumps(EXPECTED_MAIN))

    def test_changed_or_skipped_test_gate_is_blocked(self):
        for key, value in [('needs', []), ('if', 'always()'), ('secrets', 'inherit')]:
            main = copy.deepcopy(EXPECTED_MAIN)
            main['jobs']['unsigned_ipa'][key] = value
            self.blocked_safely(lambda: validate_workflow_values(main, EXPECTED_CHILD))
        main = copy.deepcopy(EXPECTED_MAIN)
        main['jobs']['public_synthetic_validation']['steps'][6]['continue-on-error'] = True
        self.blocked_safely(lambda: validate_workflow_values(main, EXPECTED_CHILD))

    def test_external_upload_and_secrets_are_blocked(self):
        for value in ['**/*', CANARY + '.log', 'Payload']:
            child = copy.deepcopy(EXPECTED_CHILD)
            child['jobs']['unsigned_ipa']['steps'][-1]['with']['path'] = value
            self.blocked_safely(lambda: validate_workflow_values(EXPECTED_MAIN, child))
        child = copy.deepcopy(EXPECTED_CHILD)
        child['jobs']['unsigned_ipa']['steps'][3]['env'] = {'KEY': CANARY}
        self.blocked_safely(lambda: validate_workflow_values(EXPECTED_MAIN, child))
        child = copy.deepcopy(EXPECTED_CHILD)
        child['jobs']['unsigned_ipa']['steps'].append({'uses': 'actions/upload-artifact@v4',
                                                    'with': {'path': CANARY + '.log'}})
        self.blocked_safely(lambda: validate_workflow_values(EXPECTED_MAIN, child))

    def test_runtime_lyrics_are_inert_and_workflow_does_not_run_lyrics_regression(self):
        validate_no_lyrics_application(REPO)
        names = [step.get('name') for step in EXPECTED_MAIN['jobs']['public_synthetic_validation']['steps']]
        self.assertEqual(names.count('Source replacement synthetic tests'), 1)
        self.assertFalse(any(name and 'lyrics' in name.lower() for name in names))
        self.assertFalse(any('EvanTubePublicTests' in step.get('run', '') for step in EXPECTED_MAIN['jobs']['public_synthetic_validation']['steps']))
        original = pathlib.Path.read_text
        from unittest.mock import patch
        def alter(path, *args, **kwargs):
            value = original(path, *args, **kwargs)
            return value + '\\nonToggleLyrics()\\n' if path.name == 'PlayerBottomBarView.swift' else value
        with patch.object(pathlib.Path, 'read_text', alter):
            self.blocked_safely(lambda: validate_no_lyrics_application(REPO))

    def test_signed_native_playback_is_required_and_external_handoff_is_not(self):
        validate_verification_recovery(REPO)
        from unittest.mock import patch
        original = pathlib.Path.read_text
        def sabotage(path, *args, **kwargs):
            source = original(path, *args, **kwargs)
            if path.name == 'PlayerRepository.swift':
                return source.replace('label: "IOS(session)"', 'label: "ExternalApp"')
            return source
        with patch.object(pathlib.Path, 'read_text', sabotage):
            self.blocked_safely(lambda: validate_verification_recovery(REPO))

    def test_project_has_only_original_app_and_extension_with_new_version(self):
        project = json.loads((REPO / 'native-ios/public-ipa-project.json').read_bytes())
        validate_project(project)
        project['targets']['PrivateFixtures'] = {'sources': [CANARY]}
        self.blocked_safely(lambda: validate_project(project))

    def test_only_unsigned_arm64_device_macho_is_accepted(self):
        validate_macho(macho())
        for binary in [macho(platform=7), macho(signature_size=8), macho()[:-1], b'not-macho']:
            self.blocked_safely(lambda: validate_macho(binary))

    def test_private_credentials_resources_and_external_symlinks_are_blocked(self):
        with tempfile.TemporaryDirectory() as folder:
            app = app_fixture(folder)
            validate_app(app, set())
            secret = app / 'Secrets.plist'
            secret.write_bytes(plistlib.dumps({'KEY': CANARY}))
            self.blocked_safely(lambda: validate_app(app, set()))
            secret.write_bytes(plistlib.dumps({}))
            private = app / 'Fixtures'
            private.mkdir()
            (private / 'synthetic.json').write_text(json.dumps({'title': CANARY}))
            self.blocked_safely(lambda: validate_app(app, set()))
        with tempfile.TemporaryDirectory() as folder:
            app = app_fixture(folder)
            outside = pathlib.Path(folder) / 'synthetic.txt'
            outside.write_text(CANARY)
            (app / 'outside-link').symlink_to(outside)
            self.blocked_safely(lambda: validate_app(app, set()))

    def test_app_and_extension_build_must_match_and_json_must_be_pinned(self):
        with tempfile.TemporaryDirectory() as folder:
            app = app_fixture(folder)
            unknown = app / 'synthetic.json'
            unknown.write_text(json.dumps({'title': CANARY}))
            self.blocked_safely(lambda: validate_app(app, set()))
        with tempfile.TemporaryDirectory() as folder:
            app = app_fixture(folder)
            info = app / 'PlugIns/Synthetic.appex/Info.plist'
            data = plistlib.loads(info.read_bytes())
            data['CFBundleVersion'] = '24'
            info.write_bytes(plistlib.dumps(data))
            self.blocked_safely(lambda: validate_app(app, set()))

    def test_manifest_cannot_embed_private_metadata_or_claim_device_acceptance(self):
        clean = {'file': IPA_NAME, 'bytes': 1024, 'sha256': 'a' * 64, 'sourceSHA': 'b' * 40,
                 'version': VERSION, 'build': BUILD, 'bundleID': 'com.c63amg77771717.evantube',
                 'architecture': 'arm64', 'unsigned': True, 'archiveIntegrity': 'PASS',
                 'deviceCompilation': 'PASS', 'sourceReplacementTests': 17, 'lyricsRegressionTests': 0,
                 'lyricsEnabled': False,
                 'liveQueries': 0, 'physicalDevice': 'NOT_RUN', 'humanVerification': 'NOT_RUN',
                 'credentialsEmbedded': False}
        validate_manifest(clean)
        self.blocked_safely(lambda: validate_manifest(dict(clean, title=CANARY)))
        self.blocked_safely(lambda: validate_manifest(dict(clean, physicalDevice='PASS')))
        self.blocked_safely(lambda: validate_manifest(dict(clean, sourceReplacementTests=17.0)))

if __name__ == '__main__':
    details = io.StringIO()
    result = unittest.TextTestRunner(stream=details).run(unittest.defaultTestLoader.loadTestsFromTestCase(IPAPolicyTests))
    print(json.dumps({'ipaGuards': result.testsRun, 'failures': len(result.failures) + len(result.errors),
                      'result': 'PASS' if result.wasSuccessful() else 'FAIL'}))
    sys.exit(0 if result.wasSuccessful() else 1)
