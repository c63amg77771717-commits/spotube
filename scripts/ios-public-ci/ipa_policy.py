"""Fail-closed public build/output policy. No private inputs or raw failure output."""
import hashlib
import json
import pathlib
import plistlib
import re
import struct

VERSION = '1.0.1'
BUILD = '28'
IPA_NAME = 'EvanTube-iOS-1.0.1-build28-unsigned.ipa'
MANIFEST_NAME = 'ipa-manifest.json'
EXPECTED_MAIN = json.loads("{\"name\":\"EvanTube public synthetic native tests\",\"on\":{\"workflow_dispatch\":{},\"push\":{\"branches\":[\"codex/ios-neonoir-20260930\"],\"paths\":[\"native-ios/**\",\"scripts/ios-public-ci/**\",\"scripts/ios-source-replacement/**\",\".github/workflows/evantube-native-ios-ipa.yml\",\".github/workflows/evantube-public-unsigned-ipa.yml\"]}},\"permissions\":{\"contents\":\"read\"},\"concurrency\":{\"group\":\"evantube-public-synthetic-${{ github.ref }}\",\"cancel-in-progress\":true},\"jobs\":{\"public_synthetic_validation\":{\"runs-on\":\"macos-14\",\"timeout-minutes\":60,\"steps\":[{\"uses\":\"actions/checkout@v4\",\"with\":{\"persist-credentials\":false}},{\"name\":\"Reject live input and unreviewed public test resources\",\"run\":\"python3 scripts/ios-public-ci/boundary.py preflight\"},{\"name\":\"Verify synthetic leak guards and strict receipt checks\",\"run\":\"python3 scripts/ios-public-ci/boundary_tests.py\"},{\"name\":\"Verify IPA workflow and output privacy guards\",\"run\":\"python3 scripts/ios-public-ci/ipa_policy_tests.py\"},{\"uses\":\"maxim-lobanov/setup-xcode@v1\",\"with\":{\"xcode-version\":\"16.2\"}},{\"name\":\"Prepare simulator test dependencies\",\"working-directory\":\"native-ios\",\"run\":\"brew install xcodegen\\ncp Secrets.plist.example LovelyMusic/Resources/Secrets.plist\\n/usr/libexec/PlistBuddy -c 'Delete :YOUTUBE_DATA_API_KEY' LovelyMusic/Resources/Secrets.plist || true\\npython3 - <<'PY'\\nimport os, pathlib, plistlib\\npathlib.Path(os.environ['RUNNER_TEMP'], 'evantube-simulator.entitlements').write_bytes(plistlib.dumps({\\n    'application-identifier': 'com.c63amg77771717.evantube',\\n    'keychain-access-groups': ['com.c63amg77771717.evantube'], 'get-task-allow': True}))\\nPY\"},{\"name\":\"Source replacement synthetic tests\",\"run\":\"python3 scripts/ios-source-replacement/run_native.py\"}]},\"unsigned_ipa\":{\"needs\":\"public_synthetic_validation\",\"uses\":\"./.github/workflows/evantube-public-unsigned-ipa.yml\",\"permissions\":{\"contents\":\"read\"}}}}")
EXPECTED_CHILD = json.loads("{\"name\":\"EvanTube public unsigned IPA\",\"on\":{\"workflow_call\":{}},\"permissions\":{\"contents\":\"read\"},\"jobs\":{\"unsigned_ipa\":{\"runs-on\":\"macos-14\",\"timeout-minutes\":60,\"steps\":[{\"uses\":\"actions/checkout@v4\",\"with\":{\"persist-credentials\":false}},{\"uses\":\"actions/setup-python@v5\",\"with\":{\"python-version\":\"3.12\"}},{\"uses\":\"maxim-lobanov/setup-xcode@v1\",\"with\":{\"xcode-version\":\"16.2\"}},{\"name\":\"Compile and validate credential-free unsigned IPA\",\"run\":\"python3 scripts/ios-public-ci/build_ipa.py\"},{\"name\":\"Upload only validated unsigned IPA and safe manifest\",\"uses\":\"actions/upload-artifact@v4\",\"with\":{\"name\":\"EvanTube-iOS-1.0.1-build28-unsigned-${{ github.sha }}\",\"path\":\"${{ runner.temp }}/evantube-public-ipa/out/EvanTube-iOS-1.0.1-build28-unsigned.ipa\\n${{ runner.temp }}/evantube-public-ipa/out/ipa-manifest.json\",\"if-no-files-found\":\"error\",\"retention-days\":3}}]}}}")
MANIFEST_KEYS = {'file', 'bytes', 'sha256', 'sourceSHA', 'version', 'build', 'bundleID',
                 'architecture', 'unsigned', 'archiveIntegrity', 'deviceCompilation',
                 'sourceReplacementTests', 'lyricsRegressionTests', 'lyricsEnabled', 'liveQueries',
                 'physicalDevice', 'humanVerification', 'credentialsEmbedded'}

class PolicyBlocked(Exception):
    pass

def require(condition):
    if not condition:
        raise PolicyBlocked('PUBLIC_IPA_BLOCKED')

def validate_workflow_values(main, child):
    # Exact documents reject skipped test gates, inherited credentials,
    # wildcard uploads, diagnostic artifacts and any additional output.
    require(json.dumps(main, sort_keys=True) == json.dumps(EXPECTED_MAIN, sort_keys=True))
    require(json.dumps(child, sort_keys=True) == json.dumps(EXPECTED_CHILD, sort_keys=True))

def validate_verification_recovery(repo):
    """Require signed, in-app native playback before optional fallback clients."""
    paths = {
        'repository': 'native-ios/LovelyMusic/Data/Repositories/PlayerRepository.swift',
        'api': 'native-ios/LovelyMusic/InnerTube/InnerTube.swift',
        'auth': 'native-ios/LovelyMusic/Core/Auth/YouTubeAuthManager.swift',
        'view': 'native-ios/LovelyMusic/Presentation/Player/FullPlayerView.swift',
        'tests': 'native-ios/EvanTubeTests/PlaybackSourceReplacementTests.swift',
    }
    try:
        src = {k: (repo / path).read_text(encoding='utf8') for k, path in paths.items()}
    except OSError:
        raise PolicyBlocked('PUBLIC_IPA_NATIVE_AUTH_BLOCKED') from None
    require('label: "IOS(session)"' in src['repository'])
    require('let cpn = generateCPN()' in src['repository'])
    require('if api is InnerTubeAPI, !SecretsProvider.hasPlayerSourceConfiguration' in src['repository'])
    require('throw InnerTubeError.videoUnavailable(reason: failure.reason)' in src['repository'])
    require('sessionAuthorizationHeader(' in src['api'])
    require('YouTubeAuthManager.sessionAuthorizationHeader' in src['api'])
    require('static func sessionAuthorizationHeader(' in src['auth'])
    require('YouTubeLoginView(authManager:' in src['view'])
    require('youtube_official_playback' not in src['view'])
    require('YouTubeOfficialPlaybackPolicy' not in src['tests'])
    require('SAPISIDHASH 1234_' in src['tests'])

def validate_no_lyrics_application(repo):
    """Fail closed if playback restores a lyric request, UI entry, or live provider."""
    checks = {
        'player': repo / 'native-ios/LovelyMusic/Presentation/Player/PlayerViewModel.swift',
        'ui': repo / 'native-ios/LovelyMusic/Presentation/Player/FullPlayerView.swift',
        'bar': repo / 'native-ios/LovelyMusic/Presentation/Player/Components/PlayerBottomBarView.swift',
        'settings': repo / 'native-ios/LovelyMusic/Presentation/Settings/PlaybackAudioSettingsView.swift',
        'di': repo / 'native-ios/LovelyMusic/App/DIContainer.swift',
        'provider': repo / 'native-ios/LovelyMusic/Domain/Protocols/LyricsRepositoryProtocol.swift',
        'app': repo / 'native-ios/LovelyMusic/App/LovelyMusicApp.swift',
    }
    try:
        source = {name: file.read_text(encoding='utf8') for name, file in checks.items()}
    except OSError:
        raise PolicyBlocked('PUBLIC_IPA_LYRICS_DISABLED_CONTRACT') from None
    require('private func requestLyrics(for song: Song) {}' in source['player'])
    require('func loadLyrics(for song: Song) async { cancelLyricsRequest() }' in source['player'])
    require('getLyricsUseCase.executeReport(' not in source['player'])
    require('await self?.loadLyrics(for: song)' not in source['player'])
    require('onToggleLyrics' not in source['bar'])
    require('isLyricsVisible' not in source['bar'])
    require('SyncedLyricsScrollView(' not in source['ui'])
    require('inlineLyricsView' not in source['ui'])
    require('isLyricsVisible' not in source['ui'])
    require('header: "Lyrics"' not in source['settings'])
    require('lyrics_lrcapi_enabled' not in source['settings'])
    require('onChange(of: viewModel.isLrcApiEnabled)' not in source['settings'])
    require('let lyricsRepo: LyricsRepositoryProtocol = DisabledLyricsRepository()' in source['di'])
    require('CompositeLyricsRepository(' not in source['di'])
    require('struct DisabledLyricsRepository: LyricsRepositoryProtocol' in source['provider'])
    require('return .legacy(nil)' in source['provider'])
    require('retryInterruptedLyrics()' not in source['app'])

def validate_workflows(repo):
    try:
        main = json.loads((repo / '.github/workflows/evantube-native-ios-ipa.yml').read_bytes())
        child = json.loads((repo / '.github/workflows/evantube-public-unsigned-ipa.yml').read_bytes())
        validate_workflow_values(main, child)
        validate_no_lyrics_application(repo)
        validate_verification_recovery(repo)
    except (OSError, ValueError, KeyError):
        raise PolicyBlocked('PUBLIC_IPA_WORKFLOW_BLOCKED') from None

def validate_project(project):
    require(set(project['targets']) == {'LovelyMusic', 'LovelyMusicNotificationService'})
    require(project['schemes'] == {'LovelyMusic': {'build': {'targets': {'LovelyMusic': 'all'}}, 'archive': {'config': 'Release'}}})
    require(project['settings']['configs']['Release']['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] == '')
    for name in ('LovelyMusic', 'LovelyMusicNotificationService'):
        target = project['targets'][name]
        require(target['sources'] == [{'path': name}])
        settings = target['settings']['base']
        require(settings['CURRENT_PROJECT_VERSION'] == BUILD and settings['MARKETING_VERSION'] == VERSION)
        require(settings['PRODUCT_BUNDLE_IDENTIFIER'] == 'com.c63amg77771717.evantube' +
                ('.NotificationService' if name == 'LovelyMusicNotificationService' else ''))
    raw = json.dumps(project)
    require(not any(value in raw for value in ['EvanTubeTests', 'Fixtures', 'UITests', 'EVANTUBE_PUBLIC_CI']))

def validate_macho(binary):
    require(len(binary) >= 32)
    header = struct.unpack_from('<8I', binary)
    require(header[0] == 0xfeedfacf and header[1] == 0x0100000c and header[3] == 2)
    offset = 32
    device_platform = False
    require(header[4] < 10000 and 32 + header[5] <= len(binary))
    for _ in range(header[4]):
        require(offset + 8 <= len(binary))
        command, size = struct.unpack_from('<II', binary, offset)
        require(size >= 8 and offset + size <= 32 + header[5])
        if command == 0x32:
            require(size >= 24)
            require(struct.unpack_from('<I', binary, offset + 8)[0] == 2)
            device_platform = True
        if command == 0x25:
            device_platform = True
        if command == 0x1d:
            require(size >= 16 and struct.unpack_from('<I', binary, offset + 12)[0] == 0)
        offset += size
    require(offset == 32 + header[5] and device_platform)

def validate_app(app, allowed_json_hashes):
    require(app.is_dir() and not app.is_symlink())
    root = app.resolve()
    forbidden_parts = {'fixtures', 'evantubetests', 'lovelymusictests', 'lovelymusicuitests',
                       'diagnostics', 'logs', '_codesignature'}
    for path in app.rglob('*'):
        require(path.resolve().is_relative_to(root))
        relative = path.relative_to(app)
        require(not any(part.lower() in forbidden_parts for part in relative.parts))
        require(path.name.lower() != 'embedded.mobileprovision')
        require(path.suffix.lower() not in {'.log', '.xcresult', '.xctest', '.dSYM'.lower()})
        if path.is_file() and path.suffix.lower() == '.json':
            require(hashlib.sha256(path.read_bytes().replace(b'\r\n', b'\n')).hexdigest() in allowed_json_hashes)
    secret_files = list(app.rglob('Secrets.plist'))
    require(len(secret_files) == 1 and plistlib.loads(secret_files[0].read_bytes()) == {})
    extensions = list(app.glob('PlugIns/*.appex'))
    require(len(extensions) == 1)
    for bundle, identifier in [(app, 'com.c63amg77771717.evantube'),
                               (extensions[0], 'com.c63amg77771717.evantube.NotificationService')]:
        info = plistlib.loads((bundle / 'Info.plist').read_bytes())
        require(info['CFBundleVersion'] == BUILD and info['CFBundleShortVersionString'] == VERSION)
        require(info['CFBundleIdentifier'] == identifier)
        executable = info['CFBundleExecutable']
        require(isinstance(executable, str) and pathlib.PurePath(executable).name == executable)
        validate_macho((bundle / executable).read_bytes())
    return plistlib.loads((app / 'Info.plist').read_bytes())

def validate_manifest(value):
    require(isinstance(value, dict) and set(value) == MANIFEST_KEYS)
    require(value['file'] == IPA_NAME and value['version'] == VERSION and value['build'] == BUILD)
    require(value['bundleID'] == 'com.c63amg77771717.evantube')
    require(type(value['bytes']) is int and 0 < value['bytes'] <= 512 * 1024 * 1024)
    require(isinstance(value['sourceSHA'], str) and re.fullmatch('[a-f0-9]{40}', value['sourceSHA']) is not None)
    require(isinstance(value['sha256'], str) and re.fullmatch('[a-f0-9]{64}', value['sha256']) is not None)
    require(value['architecture'] == 'arm64' and value['unsigned'] is True)
    require(value['archiveIntegrity'] == 'PASS' and value['deviceCompilation'] == 'PASS')
    require(type(value['sourceReplacementTests']) is int and value['sourceReplacementTests'] == 17)
    require(type(value['lyricsRegressionTests']) is int and value['lyricsRegressionTests'] == 0)
    require(value['lyricsEnabled'] is False)
    require(type(value['liveQueries']) is int and value['liveQueries'] == 0 and value['credentialsEmbedded'] is False)
    require(value['physicalDevice'] == 'NOT_RUN' and value['humanVerification'] == 'NOT_RUN')
