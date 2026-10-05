import assert from 'node:assert/strict';

// Observe only. Never write preferences or relax the exact boolean persistence oracle.
export async function observePersistedPreferences(read, expectedEnabled, {
  timeoutMs = 15000, intervalMs = 500, sleep,
  now = () => performance.now(), record = () => {},
} = {}) {
  assert.equal(typeof expectedEnabled, 'boolean');
  assert(timeoutMs > 0 && intervalMs > 0 && typeof sleep === 'function');
  const start = now();
  const observations = [];
  const maxReads = Math.ceil(timeoutMs / intervalMs) + 1;
  let latest;
  for (let attempt = 1; attempt <= maxReads; attempt++) {
    latest = await read();
    const elapsedMs = now() - start;
    observations.push({ attempt, elapsedMs, preferences: latest });
    record(observations);
    if (latest['lyrics.secondary.lrcapi.enabled'] === expectedEnabled) return latest;
    if (elapsedMs >= timeoutMs || attempt === maxReads) break;
    await sleep(Math.min(intervalMs, timeoutMs - elapsedMs));
  }
  assert.equal(latest?.['lyrics.secondary.lrcapi.enabled'], expectedEnabled,
    `Raw preferences plist did not reach the expected boolean within ${timeoutMs}ms`);
}
