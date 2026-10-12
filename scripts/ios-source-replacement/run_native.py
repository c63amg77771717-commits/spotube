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
        print('SOURCE_REPLACEMENT_BLOCKED_OR_FAILED; detailed output remains runner-local', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
