"""Public CI accepts pinned synthetic inputs and emits fixed aggregates only.

Detailed logs/xcresults are temporary runner files. This module never uploads
them, prints upstream bodies, dispatch inputs, exceptions, or source metadata.
"""
import argparse
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
from fixtures import encoded, synthetic_manifests

TEST_SOURCES = [
    'EvanTubeTests/LyricsDirectionRepositoryClosureTests.swift',
    'EvanTubeTests/LyricsNativeReceiptTests.swift',
    'EvanTubeTests/LyricsLiveReceiptSupport.swift',
    'EvanTubeTests/LyricsPublicBoundaryTests.swift',
]
RESOURCE_PATHS = [f'EvanTubeTests/Fixtures/fixed_lyrics_batch{x}.json' for x in (1, 2)] + [
    'EvanTubeTests/Fixtures/lyrics_receipt_run_context.json']
SUMMARY_KEYS = {'result', 'syntheticRows', 'unitTests', 'leakGuards', 'liveQueries', 'humanVerification', 'packageBuilt'}


class BoundaryBlocked(Exception):
    pass


def input_digest(data):
    # Git checkouts differ in text line endings between Windows and macOS.
    # Binary resources retain their exact bytes.
    if b'\0' not in data:
        try:
            data.decode('utf8')
            data = data.replace(b'\r\n', b'\n')
        except UnicodeDecodeError:
            pass
    return hashlib.sha256(data).hexdigest()


def require(condition):
    if not condition:
        raise BoundaryBlocked('PUBLIC_CI_INPUT_BLOCKED')


def validate_event(event, event_name):
    require(event_name in {'push', 'workflow_dispatch'})
    require(isinstance(event, dict) and not event.get('inputs'))


def aggregate(value):
    # Reject nested objects and extra keys, even if apparently anonymous.
    require(isinstance(value, dict) and set(value) == SUMMARY_KEYS)
    require(value['result'] in {'PASS', 'FAIL'})
    for key in ('syntheticRows', 'unitTests', 'leakGuards', 'liveQueries'):
        require(type(value[key]) is int and 0 <= value[key] <= 1000)
    require(value['liveQueries'] == 0 and value['humanVerification'] == 'NOT_RUN' and value['packageBuilt'] is False)
    return json.dumps(value, sort_keys=True)


def preflight(repo, event=None, event_name=None, environ=None):
    env = os.environ if environ is None else environ
    if event_name is not None:
        validate_event(event, event_name)
    # These legacy environment channels must never reach a printable step.
    require(not any(key in env for key in ['EVANTUBE_SAMPLE_JSON', 'INPUTS_JSON', 'EVANTUBE_FIRST_SAMPLE_RUN']))
    require(not (repo / 'native-ios/EvanTubeTests/Fixtures/authorized_random_lyrics_sample.json').exists())
    require(not (repo / 'native-ios/EvanTubeTests/Fixtures/lyrics_receipt_run_context.json').exists())
    lock = json.loads((repo / 'scripts/ios-public-ci/input-lock.json').read_bytes())
    require(lock.get('schema') == 'evantube-public-ci-input-lock-v1' and lock.get('dataOrigin') == 'entirelySynthetic')
    for name, digest in lock['inputs'].items():
        target = (repo / name).resolve()
        require(target.is_relative_to(repo.resolve()) and target.is_file())
        require(input_digest(target.read_bytes()) == digest)
    for batch, value in enumerate(synthetic_manifests(), 1):
        require((repo / f'native-ios/EvanTubeTests/Fixtures/fixed_lyrics_batch{batch}.json').read_bytes() == encoded(value))
    project = json.loads((repo / 'native-ios/public-ci-project.json').read_bytes())
    require(set(project['targets']) == {'LovelyMusic', 'LovelyMusicNotificationService', 'EvanTubePublicTests'})
    require(set(project['schemes']) == {'EvanTubePublicTests'})
    test = project['targets']['EvanTubePublicTests']
    require(test['sources'] == [{'path': x} for x in TEST_SOURCES] + [{'path': x, 'buildPhase': 'resources'} for x in RESOURCE_PATHS])
    require(test['settings']['base']['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] == '$(inherited) EVANTUBE_PUBLIC_CI')
    workflow = (repo / '.github/workflows/evantube-native-ios-ipa.yml').read_text(encoding='utf8')
    require(not any(x in workflow for x in ['upload-artifact', 'toJSON(', '${{ inputs.', 'random_sample_json', 'EVANTUBE_SAMPLE_JSON']))


def captured_command(command, cwd, destination):
    # Never include a command, exception or its output in a raised/public error.
    try:
        with destination.open('wb') as output:
            completed = subprocess.run(command, cwd=cwd, stdout=output, stderr=subprocess.STDOUT, check=False)
        require(completed.returncode == 0)
    except (OSError, subprocess.SubprocessError):
        raise BoundaryBlocked('PUBLIC_CI_COMMAND_FAILED') from None


def run_native(repo, temporary):
    temporary.mkdir(parents=True, exist_ok=True)
    bundle = temporary / 'evantube-public-native.xcresult'
    log = temporary / 'native-tests-local-only.log'
    command = ['xcodebuild', '-project', 'LovelyMusic.xcodeproj', '-scheme', 'EvanTubePublicTests', '-configuration', 'Debug',
               '-destination', 'platform=iOS Simulator,name=iPhone 16 Pro', '-derivedDataPath', str(temporary / 'public-derived'),
               '-parallel-testing-enabled', 'NO', '-only-testing:EvanTubePublicTests', '-resultBundlePath', str(bundle),
               'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_IDENTITY=-', 'CODE_SIGN_ENTITLEMENTS=' + str(temporary / 'evantube-simulator.entitlements'), 'test']
    captured_command(command, repo / 'native-ios', log)
    raw = log.read_text(encoding='utf8', errors='replace')
    counts = re.findall(r'Executed (\d+) tests?, with (\d+) failures?', raw)
    require(counts and counts[-1] == ('16', '0'))
    receipt = temporary / 'synthetic-native-receipt-local-only.json'
    captured_command([sys.executable, 'scripts/ios-lyrics-sample/export_native_mock_receipt.py', '--bundle', str(bundle),
                      '--source', os.environ['GITHUB_SHA'], '--output', str(receipt)], repo, temporary / 'export-local-only.log')
    from validate_mock import check
    result = check(repo, receipt)
    require(result['validation'] == 'PASS')
    return {'result': 'PASS', 'syntheticRows': 40, 'unitTests': 16, 'leakGuards': 0, 'liveQueries': 0,
            'humanVerification': 'NOT_RUN', 'packageBuilt': False}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['preflight', 'native'])
    parser.add_argument('--repo', type=pathlib.Path, default=pathlib.Path.cwd())
    parser.add_argument('--temporary', type=pathlib.Path)
    args = parser.parse_args()
    try:
        if args.action == 'preflight':
            event = json.loads(pathlib.Path(os.environ['GITHUB_EVENT_PATH']).read_bytes()) if 'GITHUB_EVENT_PATH' in os.environ else None
            preflight(args.repo, event, os.environ.get('GITHUB_EVENT_NAME'))
            print('PUBLIC_CI_PREFLIGHT_PASS synthetic inputs pinned; no live input or diagnostic upload')
        else:
            require(args.temporary is not None)
            print(aggregate(run_native(args.repo, args.temporary)))
    except Exception:
        print('PUBLIC_CI_BLOCKED_OR_FAILED; detailed output is runner-local only', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
