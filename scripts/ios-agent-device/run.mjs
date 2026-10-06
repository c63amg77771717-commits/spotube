import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { fullPlayerProgress, fullPlayerButton, currentRef } from './accessibility-selectors.mjs';
import { retryUndispatchedRunnerBusy } from './runner-recovery.mjs';
import { observePersistedPreferences } from './preferences-observer.mjs';

const { createAgentDeviceClient } = await import(pathToFileURL(process.env.AGENT_DEVICE_ENTRY));
const app = 'com.c63amg77771717.evantube';
const udid = process.env.EVANTUBE_SIMULATOR_UDID;
const root = path.resolve(process.env.EVANTUBE_AGENT_EVIDENCE);
assert(udid && root && process.platform === 'darwin', 'This suite requires the selected Mac simulator');
fs.mkdirSync(root, { recursive: true });
let sequence = 0;
let caseName = 'setup';
let client;
let scenario = {};
let caseStarted = 0;
const results = [];
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

function save(name, data) {
  fs.writeFileSync(path.join(root, name), JSON.stringify(data, null, 2));
}
async function step(name, action) {
  const number = ++sequence;
  const started = Date.now();
  try {
    const result = await action();
    save(`${String(number).padStart(3, '0')}-${caseName}-${name}.json`, { name, started,
      durationMs: Date.now() - started, status: 'PASS', result });
    console.log(`PASS ${caseName}: ${name} (${Date.now() - started}ms)`);
    return result;
  } catch (error) {
    save(`${String(number).padStart(3, '0')}-${caseName}-${name}.json`, { name, started,
      durationMs: Date.now() - started, status: 'FAIL', message: error.message,
      code: error.code, details: error.details });
    throw error;
  }
}
function simctl(args, env = {}) {
  const result = spawnSync('xcrun', ['simctl', ...args], { encoding: 'utf8',
    env: { ...process.env, ...env }, timeout: 60000 });
  assert.equal(result.status, 0, `${args[0]}: ${result.stderr}`);
  return result.stdout.trim();
}
async function launch(reset = true) {
  const env = { SIMCTL_CHILD_REVIEW_MODE: '1',
    SIMCTL_CHILD_EVANTUBE_LYRICS_CANDIDATE_RESET: reset ? '1' : '0',
    SIMCTL_CHILD_EVANTUBE_LYRICS_CANDIDATE_FIXTURE: scenario.candidates ? '1' : '0',
    SIMCTL_CHILD_EVANTUBE_LRCAPI_FIXTURE: scenario.sources ? '1' : '0',
    SIMCTL_CHILD_EVANTUBE_AGENT_SCENARIO: scenario.mode ?? '' };
  await step('fixture-launch', async () => simctl(['launch', '--terminate-running-process',
    `--stdout=${path.join(root, `${caseName}-app.stdout.log`)}`,
    `--stderr=${path.join(root, `${caseName}-app.stderr.log`)}`, udid, app,
    '-hasCompletedOnboarding', 'YES', '-appLanguage', 'en', '-AppleLanguages', '(en)',
    '-AppleLocale', 'en_US', '-playerLyricsVisible', 'YES', '-evantubeSettingsPreview'], env));
  await step('agent-open-foreground', () => client.apps.open({ app, platform: 'ios', udid, foreground: true }));
  const snap = await step('initial-snapshot', () => client.capture.snapshot());
  const deny = snap.nodes.find(n => ["Don't Allow", "Don\u2019t Allow"].includes(n.label));
  if (deny) await step('dismiss-preview-notification', () => client.interactions.press({
    ref: currentRef(snap, deny) }));
}
async function waitID(id, timeoutMs = 20000) {
  return step(`wait-${id}`, () => client.command.wait({ selector: `id="${id}"`, timeoutMs }));
}
async function waitText(text, timeoutMs = 20000) {
  return step('wait-text', () => client.command.wait({ text, timeoutMs }));
}
async function pressID(id, settle = true, role, readinessTimeoutMs) {
  const selector = `${role ? `role="${role}" ` : ''}id="${id}"`;
  return retryUndispatchedRunnerBusy(
    attempt => step(`press-${id}-attempt-${attempt}`, () => client.interactions.press({
      selector, settle, ...(readinessTimeoutMs ? { readinessTimeoutMs } : {}) })),
    sleep, evidence => save(`${caseName}-runner-busy-recovery-${sequence}.json`, evidence));
}
async function pressLabel(label, settle = true) {
  return step('press-label', () => client.interactions.press({ selector: `label="${label}"`, settle }));
}
async function screenshot(name) {
  return step(`screenshot-${name}`, () => client.capture.screenshot({ path: path.join(root, `${caseName}-${name}.png`) }));
}
async function snapshot() { return step('snapshot', () => client.capture.snapshot()); }
async function fullPlayer() {
  await waitID('dock_mini_player');
  const snap = await snapshot();
  const node = snap.nodes.find(n => n.identifier === 'dock_mini_player');
  assert(node?.rect?.width > 0, 'Mini-player geometry must come from the current AX snapshot');
  await step('open-player-at-label-side', () => client.interactions.press({
    x: node.rect.x + node.rect.width * 0.2, y: node.rect.y + node.rect.height * 0.5, settle: true }));
  await waitText('Next track');
}
async function absent(id) {
  return step(`absent-${id}`, () => client.command.wait({ absent: `id="${id}"`, timeoutMs: 5000 }));
}
function fixtureEvents() {
  const container = simctl(['get_app_container', udid, app, 'data']);
  const file = path.join(container, 'Documents/agent-device-fixture.ndjson');
  if (!fs.existsSync(file)) return [];
  const events = fs.readFileSync(file, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse)
    .filter(event => event.time >= caseStarted);
  save(`${caseName}-fixture-events.json`, events);
  return events;
}
function readPreferencesFile() {
  const container = simctl(['get_app_container', udid, app, 'data']);
  const file = path.join(container, 'Library/Preferences', `${app}.plist`);
  const code = `import json,plistlib,sys; d=plistlib.load(open(sys.argv[1],'rb')); print(json.dumps({k:v for k,v in d.items() if k == 'lyrics.secondary.lrcapi.enabled' or k.startswith('lyrics.selection.')}))`;
  const result = spawnSync('python3', ['-c', code, file], { encoding: 'utf8', timeout: 10000 });
  assert.equal(result.status, 0, result.stderr);
  const value = JSON.parse(result.stdout);
  save(`${caseName}-preferences-${sequence}.json`, value);
  return value;
}
async function preferences(expectedEnabled) {
  // Read the preference in the newly launched App process as well as the raw plist.
  const launches = fixtureEvents().filter(event => event.kind === 'launch_preferences');
  const latest = launches.at(-1);
  assert.equal(latest?.secondaryEnabled, expectedEnabled,
    'The fresh App process must read the expected source preference');
  assert(launches.length >= 2 && latest.pid !== launches.at(-2).pid,
    'Preference evidence must come from an actual new App process');
  return step('observe-persisted-source-preference', () => observePersistedPreferences(
    readPreferencesFile, expectedEnabled, { sleep,
      record: observations => save(`${caseName}-preferences-observations-${sequence}.json`, observations) }));
}
async function settings() {
  await pressLabel('Close player');
  await pressID('tab_library');
  await pressID('library_settings', true, 'button');
  await step('open-playback-settings', () => client.interactions.find({ locator: 'text', query: 'Playback & Audio', action: 'click' }));
  await step('scroll-to-secondary-switch', () => client.interactions.scroll({ direction: 'down',
    until: 'id="lyrics_lrcapi_enabled"', settle: false }));
  await waitID('lyrics_lrcapi_enabled');
}
async function waitLocalResolution(id) {
  await step(`wait-local-resolution-${id}`, async () => {
    const deadline = Date.now() + 15000;
    while (Date.now() < deadline) {
      if (fixtureEvents().some(e => e.kind === 'audio' && e.videoID === id && e.outcome === 'local_wav')) return;
      await sleep(100);
    }
    assert.fail(`${id} did not finish its bounded retry with an actual local resolution`);
  });
}
async function assertNoPlaybackError() {
  const snap = await snapshot();
  assert(!snap.nodes.some(n => n.label === 'Error details'), 'A transient retry must not leave the error panel visible');
  await step('playing-state', () => client.command.wait({ selector: 'role="button" label="Pause"', timeoutMs: 20000 }));
}
async function progress() {
  const snap = await snapshot();
  // The agent snapshot can include the covered dock. Require the full-player slider.
  const node = fullPlayerProgress(snap);
  const match = `${node.label ?? ''} ${node.value ?? ''}`.match(/(\d+):(\d+)/);
  assert(match, `Unreadable playback progress: ${node.label} ${node.value}`);
  return { seconds: Number(match[1]) * 60 + Number(match[2]), node };
}

const cases = [
  ['plain-candidate-and-relaunch', { candidates: true }, async () => {
    await fullPlayer(); await waitID('lyrics_candidate_prompt');
    await pressID('lyrics_version_picker', false);
    await screenshot('candidate-list');
    await pressID('lyrics_candidate_102', false, 'button', 20000);
    await waitText('Candidate UI second recording'); await waitID('lyrics_plain_notice');
    await absent('lyrics_candidate_prompt'); await screenshot('selected-plain');
    await step('agent-close-app', () => client.apps.close({ app }));
    await launch(false); await fullPlayer(); await waitText('Candidate UI second recording');
    await waitID('lyrics_plain_notice'); await absent('lyrics_candidate_prompt');
    await screenshot('remembered-after-relaunch');
  }],
  ['cross-provider-setting-and-memory', { sources: true }, async () => {
    await fullPlayer(); await pressID('lyrics_version_picker', false);
    await waitID('lyrics_candidate_lrcapi_101'); await screenshot('provider-candidates');
    await pressID('lyrics_candidate_lrcapi_101'); await waitText('LrcApi UI first recording');
    const attribution = await step('provider-attribution', () => client.interactions.get({
      selector: 'id="lyrics_provider_attribution"', format: 'text' }));
    assert(JSON.stringify(attribution).includes('LrcApi'));
    await screenshot('selected-lrcapi');
    await settings(); await pressID('lyrics_lrcapi_enabled', false); await sleep(1800);
    await screenshot('secondary-off');
    await step('agent-close-app', () => client.apps.close({ app }));
    await launch(false); await fullPlayer(); await waitText('LRCLib UI recording');
    await waitID('lyrics_plain_notice'); await screenshot('primary-with-secondary-off');
    const disabled = await preferences(false); assert.equal(disabled['lyrics.secondary.lrcapi.enabled'], false);
    const saved = disabled['lyrics.selection.song:demo_song_morning_light']; assert(saved, 'The remembered recording must survive disabling its source');
    await settings(); await pressID('lyrics_lrcapi_enabled', false); await sleep(1800);
    await step('agent-close-app', () => client.apps.close({ app }));
    await launch(false); await fullPlayer(); await waitText('LrcApi UI first recording');
    const enabled = await preferences(true); assert.equal(enabled['lyrics.secondary.lrcapi.enabled'], true);
    assert.deepEqual(enabled['lyrics.selection.song:demo_song_morning_light'], saved);
    await screenshot('remembered-lrcapi-after-reenable');
  }],
  ['next-previous-transient-recovery', { mode: 'transient' }, async () => {
    await fullPlayer(); await assertNoPlaybackError();
    // Pause the actual full-player button so automation latency cannot cross the >3s restart threshold.
    const pauseSnapshot = await snapshot();
    const pauseButton = fullPlayerButton(pauseSnapshot, 'Pause');
    await step('pause-before-seek', () => client.interactions.press({ ref: currentRef(pauseSnapshot, pauseButton) }));
    await step('paused-state', () => client.command.wait({ selector: 'role="button" label="Play"', timeoutMs: 5000 }));
    const { node } = await progress();
    await step('seek-to-start', () => client.interactions.press({ x: node.rect.x + 1, y: node.rect.y + node.rect.height / 2 }));
    const start = await progress();
    assert(start.seconds <= 3, `Seek must actually reach the beginning before Previous: ${start.seconds}s`);
    // Previous wraps to an unresolved track, so its injected error cannot be bypassed by the cache.
    await pressLabel('Previous track', false); await waitText('Agent Last');
    await waitLocalResolution('agent_last'); await assertNoPlaybackError(); await screenshot('previous-recovered');
    await pressLabel('Next track', false); await waitText('Arcadia');
    await pressLabel('Next track', false); await waitText('Agent Next');
    await waitLocalResolution('agent_next'); await assertNoPlaybackError(); await screenshot('next-recovered');
    const events = fixtureEvents().filter(e => e.kind === 'audio');
    for (const id of ['agent_last', 'agent_next']) {
      const rows = events.filter(e => e.videoID === id);
      assert(rows.some(e => e.outcome === 'transient') && rows.some(e => e.outcome === 'local_wav'), `${id} must show a real failure followed by successful local resolution`);
    }
    assert(events.length <= 8, 'Automatic retry must remain bounded');
  }],
  ['cancel-stale-lyrics-on-next', { mode: 'stale' }, async () => {
    await fullPlayer(); await waitText('Agent lyrics Arcadia');
    await pressLabel('Next track', false);
    // Confirm the slow transport has started before cancelling it; retain the strict cancellation oracle.
    await step('wait-delayed-lyrics-start', async () => {
      const deadline = Date.now() + 3000;
      while (Date.now() < deadline) {
        if (fixtureEvents().some(e => e.kind === 'lyrics_start' && e.title === 'Agent Next' && e.delayed)) return;
        await sleep(100);
      }
      assert.fail('Agent Next must start its real delayed URLProtocol transport before cancellation');
    });
    await pressLabel('Next track', false); await waitText('Agent Last');
    await waitText('Agent lyrics Agent Last'); await sleep(9000);
    await waitText('Agent lyrics Agent Last'); await screenshot('last-song-keeps-own-lyrics');
    const events = fixtureEvents();
    assert(events.some(e => e.kind === 'lyrics_start' && e.title === 'Agent Next' && e.delayed));
    assert(events.some(e => e.kind === 'lyrics_cancel' && e.title === 'Agent Next'), 'The previous song transport must actually be cancelled');
    assert(!events.some(e => e.kind === 'lyrics_deliver' && e.title === 'Agent Next'), 'Cancelled old lyrics must not arrive late');
    await step('old-lyrics-absent', () => client.command.wait({ absent: 'label="Agent lyrics Agent Next"', timeoutMs: 5000 }));
  }],
  ['background-and-foreground-playback', { mode: 'stale' }, async () => {
    await fullPlayer(); await assertNoPlaybackError();
    const before = await progress(); await screenshot('before-background');
    await step('agent-home', () => client.command.home());
    await sleep(6000);
    await step('agent-resume-without-relaunch', () => client.apps.open({ app, platform: 'ios', udid, foreground: true }));
    await waitText('Arcadia'); await assertNoPlaybackError();
    const after = await progress();
    assert(after.seconds >= before.seconds + 4, `Background elapsed time did not advance: ${before.seconds} -> ${after.seconds}`);
    save('background-progress.json', { before: before.seconds, after: after.seconds, simulatorOnly: true });
    await screenshot('after-foreground');
  }],
];

for (const [name, config, action] of cases) {
  caseName = name; scenario = config;
  client = createAgentDeviceClient({ session: `evantube-${name}`, platform: 'ios', udid });
  const start = Date.now();
  caseStarted = start / 1000;
  try {
    await launch(true); await action();
    results.push({ name, status: 'PASS', durationMs: Date.now() - start });
  } catch (error) {
    results.push({ name, status: 'FAIL', durationMs: Date.now() - start,
      message: error.message, code: error.code, details: error.details });
    console.error(`FAIL ${name}: ${error.message}`);
    try { await screenshot('failure'); await snapshot(); } catch (captureError) {
      save(`${name}-capture-failure.json`, { message: captureError.message });
    }
  } finally {
    try { fixtureEvents(); await step('agent-close-session', () => client.sessions.close()); } catch (error) {
      save(`${name}-cleanup-failure.json`, { message: error.message });
    }
    save('results.json', { agentDeviceVersion: '0.21.20', sourceCommit: process.env.GITHUB_SHA,
      build: 19, target: 'iPhone 16 Pro Simulator', instrumentedDebugFixtures: true,
      releaseIPAModified: false, physicalIPhoneSignedLockscreen: 'NOT RUN',
      total: cases.length, passed: results.filter(r => r.status === 'PASS').length,
      failed: results.filter(r => r.status === 'FAIL').length, cases: results });
  }
}
console.log(JSON.stringify(results, null, 2));
process.exitCode = results.some(r => r.status === 'FAIL') ? 1 : 0;
