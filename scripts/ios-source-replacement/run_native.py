"""Fresh Mac CI only; synthetic native tests, no raw-output uploads."""
import json
import os
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'scripts/ios-public-ci'))
from boundary import preflight, require, captured_command


def main():
    try:
        require(sys.platform == 'darwin' and os.environ.get('GITHUB_ACTIONS') == 'true')
        require(os.environ.get('GITHUB_REPOSITORY') == 'c63amg77771717-commits/spotube')
        preflight(REPO)
        spec = json.loads((REPO / 'native-ios/public-source-replacement-project.json').read_bytes())
        target = 'EvanTubeSourceReplacementTests'
        require(set(spec['targets']) == {'LovelyMusic', 'LovelyMusicNotificationService', target})
        require(set(spec['schemes']) == {target})
        require(spec['targets'][target]['sources'] == [{'path': 'EvanTubeTests/PlaybackSourceReplacementTests.swift'}])
        temporary = pathlib.Path(os.environ['RUNNER_TEMP']) / 'evantube-source-replacement'
        temporary.mkdir(parents=True, exist_ok=True)
        captured_command(['xcodegen', 'generate', '--spec', 'public-source-replacement-project.json'],
                         REPO / 'native-ios', temporary / 'generate-local-only.log')
        captured_command(['xcodebuild', '-project', 'LovelyMusic.xcodeproj', '-scheme', target,
                          '-configuration', 'Debug', '-destination', 'platform=iOS Simulator,name=iPhone 16 Pro',
                          '-derivedDataPath', str(temporary / 'derived'), '-parallel-testing-enabled', 'NO',
                          '-only-testing:' + target, 'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_IDENTITY=-',
                          'CODE_SIGN_ENTITLEMENTS=' + str(temporary.parent / 'evantube-simulator.entitlements'), 'test'], REPO / 'native-ios', temporary / 'native-local-only.log')
        raw = (temporary / 'native-local-only.log').read_text(encoding='utf8', errors='replace')
        counts = re.findall(r'Executed (\d+) tests?, with (\d+) failures?', raw)
        require(counts and counts[-1] == ('17', '0'))
        print('SOURCE_REPLACEMENT_SYNTHETIC_PASS nativeTests=17 liveQueries=0 humanVerification=NOT_RUN packageBuilt=false')
        return 0
    except Exception:
        # Emit only source-file basenames and locations from checked-in Swift
        # source, or allowlisted synthetic test method names. Do not print raw
        # compiler messages, assertion values, user data, URLs or xcresults.
        try:
            log_file = pathlib.Path(os.environ['RUNNER_TEMP']) / 'evantube-source-replacement/native-local-only.log'
            if log_file.exists():
                log = log_file.read_text(encoding='utf8', errors='replace')
                allowed_files = {p.name for folder in ('LovelyMusic', 'EvanTubeTests')
                                 for p in (REPO / 'native-ios' / folder).rglob('*.swift')}
                errors = re.findall(r'([A-Za-z_][A-Za-z0-9_]+\\.swift):(\\d+):(\\d+):\\s*error:', log)
                checked = sorted({f'{filename}:{line}' for filename, line, _ in errors
                                  if filename in allowed_files})
                if checked:
                    print('SYNTHETIC_SWIFT_COMPILER_LOCATIONS=' + ','.join(checked[:8]), file=sys.stderr)
                allowed_tests = set(re.findall(r'func (test[A-Za-z0-9_]+)\\s*\\(',
                    (REPO / 'native-ios/EvanTubeTests/PlaybackSourceReplacementTests.swift')
                    .read_text(encoding='utf8')))
                failures = sorted({name for name in allowed_tests
                                   if re.search(r'Test Case [^\\n]*' + re.escape(name) + r'[^\\n]*failed', log)})
                if failures:
                    print('SYNTHETIC_FAILED_PUBLIC_TESTS=' + ','.join(failures), file=sys.stderr)
                if not checked and not failures:
                    group = ('SWIFT_COMPILATION' if 'SwiftCompile' in log or 'SwiftEmitModule' in log
                             else 'TEST_EXECUTION' if 'Test Case' in log
                             else 'XCODEBUILD_OR_ENVIRONMENT')
                    print('SYNTHETIC_FAILURE_PHASE=' + group, file=sys.stderr)
        except Exception:
            pass
        print('SOURCE_REPLACEMENT_BLOCKED_OR_FAILED; detailed output remains runner-local', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
