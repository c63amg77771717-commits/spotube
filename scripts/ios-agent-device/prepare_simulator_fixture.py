"""Make an isolated Debug-only CI fixture build from the existing EvanTube checkout.

No production source changes are committed by this recipe. The recipe saves its
exact diff as evidence and keeps the Release build19 IPA separate.
"""
import argparse, hashlib, json, math, pathlib, shutil, struct, subprocess, wave

parser = argparse.ArgumentParser()
parser.add_argument('--repo', type=pathlib.Path, required=True)
parser.add_argument('--evidence', type=pathlib.Path, required=True)
args = parser.parse_args()
root = args.repo.resolve()
native = root / 'native-ios'
evidence = args.evidence.resolve()
evidence.mkdir(parents=True, exist_ok=True)
mutations = []

def replace(relative, old, new):
    path = native / relative
    original_bytes = path.read_bytes()
    original = path.read_text(encoding='utf-8')
    assert original.count(old) == 1, f'Unexpected source shape: {relative}'
    path.write_text(original.replace(old, new), encoding='utf-8')
    mutations.append({'path': str(path.relative_to(root)),
        'before_sha256': hashlib.sha256(original_bytes).hexdigest(),
        'after_sha256': hashlib.sha256(path.read_bytes()).hexdigest()})

replace('LovelyMusic/App/DIContainer.swift', 'playerRepo = DemoPlayerRepository()',
    'playerRepo = AgentDevicePlayerFixture()')
replace('LovelyMusic/App/DIContainer.swift',
    'if isReviewMode, ProcessInfo.processInfo.environment["EVANTUBE_LRCAPI_FIXTURE"] == "1" {',
    '''if isReviewMode, ["transient", "stale"].contains(ProcessInfo.processInfo.environment["EVANTUBE_AGENT_SCENARIO"] ?? "") {
            let session = AgentDeviceLyricsProtocol.session()
            lyricsRepo = CompositeLyricsRepository(primary: LrcLibService(session: session),
                secondary: LrcApiService(session: session))
        } else if isReviewMode, ProcessInfo.processInfo.environment["EVANTUBE_LRCAPI_FIXTURE"] == "1" {''')
replace('LovelyMusic/App/DIContainer.swift', 'secondary: LrcApiService(session: session), secondaryEnabled: { true })',
    'secondary: LrcApiService(session: session))')
# Observe the actual preference API in each new test App process, without writing or synchronizing it.
replace('LovelyMusic/App/DIContainer.swift',
    'let session = LrcApiPreviewHTTPFixture.session(\n                resetSelection: ProcessInfo.processInfo.environment["EVANTUBE_LYRICS_CANDIDATE_RESET"] == "1")',
    '''let session = LrcApiPreviewHTTPFixture.session(
                resetSelection: ProcessInfo.processInfo.environment["EVANTUBE_LYRICS_CANDIDATE_RESET"] == "1")
            let sourceDefaults = UserDefaults.standard
            let sourceDomain = Bundle.main.bundleIdentifier ?? "missing-bundle-id"
            let storedSource = sourceDefaults.object(forKey: LyricsSecondarySettings.enabledKey)
            let domainSource = sourceDefaults.persistentDomain(forName: sourceDomain)?[LyricsSecondarySettings.enabledKey]
            AgentDeviceFixtureLog.record(["kind": "launch_preferences",
                "pid": Int(ProcessInfo.processInfo.processIdentifier),
                "secondaryEnabled": LyricsSecondarySettings.isEnabled(),
                "suite": "standard", "preferenceKey": LyricsSecondarySettings.enabledKey,
                "bundleIdentifier": sourceDomain,
                "bundleBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? NSNull(),
                "storedObject": storedSource ?? NSNull(),
                "storedObjectType": storedSource.map { String(describing: type(of: $0)) } ?? "missing",
                "applicationDomainObject": domainSource ?? NSNull(),
                "usesDefaultFallback": storedSource as? Bool == nil])''')
replace('LovelyMusic/Presentation/Navigation/ContentView.swift', '''                playerVM.play(song: Song(
                    id: "demo_song_morning_light", title: "Arcadia", artistName: "Kevin MacLeod",
                    artistId: nil, albumName: "Peaceful Moments", albumId: nil,
                    duration: 98, thumbnailURL: "demo_album_peaceful"
                ))''', '''                let songs = [
                    Song(id: "demo_song_morning_light", title: "Arcadia", artistName: "Kevin MacLeod",
                        artistId: nil, albumName: nil, albumId: nil, duration: 98, thumbnailURL: nil),
                    Song(id: "agent_next", title: "Agent Next", artistName: "Fixture Artist",
                        artistId: nil, albumName: nil, albumId: nil, duration: 98, thumbnailURL: nil),
                    Song(id: "agent_last", title: "Agent Last", artistName: "Fixture Artist",
                        artistId: nil, albumName: nil, albumId: nil, duration: 98, thumbnailURL: nil)
                ]
                let needsQueue = ["transient", "stale"].contains(ProcessInfo.processInfo.environment["EVANTUBE_AGENT_SCENARIO"] ?? "")
                playerVM.play(song: songs[0], fromQueue: needsQueue ? songs : [songs[0]])''')
fixture = native / 'LovelyMusic/App/AgentDeviceAutomationFixture.swift'
assert not fixture.exists()
shutil.copyfile(pathlib.Path(__file__).with_name('AgentDeviceAutomationFixture.swift'), fixture)
audio = native / 'LovelyMusic/Resources/agent_device_audio.wav'
assert not audio.exists()
with wave.open(str(audio), 'wb') as out:
    out.setnchannels(1); out.setsampwidth(2); out.setframerate(8000)
    # Synthetic, low amplitude local audio. No CDN, external media or private files.
    out.writeframes(b''.join(struct.pack('<h', int(900 * math.sin(2 * math.pi * 220 * i / 8000)))
                             for i in range(98 * 8000)))
diff = subprocess.run(['git', 'diff', '--', 'native-ios'], cwd=root, check=True,
    capture_output=True, encoding='utf-8').stdout
(evidence / 'simulator-fixture.patch').write_text(diff, encoding='utf-8')
receipt = {'source_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
    'mode': 'instrumented Debug simulator; original Release IPA untouched', 'mutations': mutations,
    'fixture_sha256': hashlib.sha256(fixture.read_bytes()).hexdigest(),
    'local_wav_sha256': hashlib.sha256(audio.read_bytes()).hexdigest(),
    'external_lyrics_requests': 0, 'private_playlist_upload': False}
(evidence / 'fixture-preparation.json').write_text(json.dumps(receipt, indent=2), encoding='utf-8')
print(json.dumps(receipt, indent=2))
