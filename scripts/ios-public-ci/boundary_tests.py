"""Synthetic canaries verify fail-closed input and output boundaries."""
import contextlib
import copy
import io
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from boundary import BoundaryBlocked, aggregate, captured_command, input_digest, preflight, validate_event
from fixtures import encoded, synthetic_manifests
from validate_mock import self_test

REPO = pathlib.Path(__file__).resolve().parents[2]
CANARY = 'SYNTHETIC_SECRET_CANARY_TITLE_AND_ARTIST_976'


class PublicBoundaryTests(unittest.TestCase):
    def blocked_without_canary(self, action):
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            with self.assertRaises(BoundaryBlocked) as error:
                action()
        self.assertNotIn(CANARY, stdout.getvalue() + stderr.getvalue() + str(error.exception))

    def test_dispatch_rejects_any_inputs(self):
        for value in ({'random_sample_json': CANARY}, {'unexpected': CANARY}, {'source_queries_authorized': True}):
            self.blocked_without_canary(lambda: validate_event({'inputs': value}, 'workflow_dispatch'))

    def test_dispatch_empty_and_push_allowed(self):
        validate_event({'inputs': {}}, 'workflow_dispatch')
        validate_event({}, 'push')

    def test_other_event_blocked(self):
        self.blocked_without_canary(lambda: validate_event({'inputs': {}}, 'pull_request'))

    def test_text_checkout_line_endings_and_binary_integrity(self):
        self.assertEqual(input_digest(b'synthetic\r\ntext\r\n'), input_digest(b'synthetic\ntext\n'))
        self.assertNotEqual(input_digest(b'\0\r\n'), input_digest(b'\0\n'))
        self.assertNotEqual(input_digest(CANARY.encode()), input_digest(b'synthetic\n'))

    def test_legacy_env_channels_blocked(self):
        for key in ('EVANTUBE_SAMPLE_JSON', 'INPUTS_JSON', 'EVANTUBE_FIRST_SAMPLE_RUN'):
            self.blocked_without_canary(lambda: preflight(REPO, environ={key: CANARY}))

    def test_legacy_ci_loader_blocks_before_parsing(self):
        import os
        env = os.environ.copy()
        env.update(GITHUB_ACTIONS='true', EVANTUBE_SAMPLE_JSON=CANARY)
        process = subprocess.run([sys.executable, str(REPO/'scripts/ios-lyrics-sample/prepare_ci_manifest.py')],
                                 cwd=REPO, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.assertNotEqual(process.returncode, 0)
        self.assertIn('PRIVATE_LIVE_MANIFEST_BLOCKED_IN_CI', process.stderr)
        self.assertNotIn(CANARY, process.stdout + process.stderr)

    def test_unexpected_live_resource_blocked(self):
        original = pathlib.Path.exists
        with patch.object(pathlib.Path, 'exists', lambda path: True if path.name == 'authorized_random_lyrics_sample.json' else original(path)):
            self.blocked_without_canary(lambda: preflight(REPO, environ={}))

    def test_modified_manifest_blocked(self):
        original = pathlib.Path.read_bytes
        with patch.object(pathlib.Path, 'read_bytes', lambda path: CANARY.encode() if path.name == 'fixed_lyrics_batch1.json' else original(path)):
            self.blocked_without_canary(lambda: preflight(REPO, environ={}))

    def test_modified_source_blocked(self):
        original = pathlib.Path.read_bytes
        with patch.object(pathlib.Path, 'read_bytes', lambda path: CANARY.encode() if path.name == 'LyricsNativeReceiptTests.swift' else original(path)):
            self.blocked_without_canary(lambda: preflight(REPO, environ={}))

    def test_allowlist_disallows_extra_resource(self):
        original = pathlib.Path.read_bytes
        def changed(path):
            raw = original(path)
            if path.name == 'public-ci-project.json':
                value = json.loads(raw)
                value['targets']['EvanTubePublicTests']['sources'].append({'path': CANARY, 'buildPhase': 'resources'})
                return encoded(value)
            return raw
        with patch.object(pathlib.Path, 'read_bytes', changed):
            self.blocked_without_canary(lambda: preflight(REPO, environ={}))

    def test_no_diagnostic_artifact_upload(self):
        workflow = (REPO / '.github/workflows/evantube-native-ios-ipa.yml').read_text()
        for value in ('upload-artifact', 'toJSON(', '${{ inputs.', 'random_sample_json'):
            self.assertNotIn(value, workflow)

    def test_summary_rejects_private_fields(self):
        clean = {'result':'PASS','syntheticRows':40,'unitTests':16,'leakGuards':13,'liveQueries':0,'humanVerification':'NOT_RUN','packageBuilt':False}
        self.assertNotIn(CANARY, aggregate(clean))
        for key in ('title','artist','queryLedger','exception','screenshot'):
            bad = dict(clean, **{key: CANARY})
            self.blocked_without_canary(lambda: aggregate(bad))
        bad = dict(clean, result=CANARY)
        self.blocked_without_canary(lambda: aggregate(bad))

    def test_failed_command_never_prints_output_or_exception(self):
        with tempfile.TemporaryDirectory() as folder:
            target = pathlib.Path(folder) / 'local-only.log'
            command = [sys.executable, '-c', 'import sys; print(' + repr(CANARY) + '); sys.exit(7)']
            self.blocked_without_canary(lambda: captured_command(command, REPO, target))
            self.assertIn(CANARY, target.read_text())

    def test_fixture_generation_has_no_external_input(self):
        manifests = synthetic_manifests()
        self.assertEqual([len(x['samples']) for x in manifests], [20,20])
        for batch, value in enumerate(manifests,1):
            self.assertEqual(value['dataOrigin'],'entirelySynthetic')
            self.assertEqual((REPO/f'native-ios/EvanTubeTests/Fixtures/fixed_lyrics_batch{batch}.json').read_bytes(),encoded(value))
        self.assertEqual(manifests[1]['previousManifestSHA256'],manifests[0]['manifestSHA256'])

    def test_strict_ledger_positive_and_negative_cases(self):
        self.assertEqual(self_test(REPO)['offlineSelfTest'],'PASS')


if __name__ == '__main__':
    # Unit assertion details can contain an injected input. Only emit counts.
    stream = io.StringIO()
    result = unittest.TextTestRunner(stream=stream).run(unittest.defaultTestLoader.loadTestsFromTestCase(PublicBoundaryTests))
    print(json.dumps({'leakGuards':result.testsRun,'failures':len(result.failures)+len(result.errors),'result':'PASS' if result.wasSuccessful() else 'FAIL'}))
    sys.exit(0 if result.wasSuccessful() else 1)
