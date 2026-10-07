import test from 'node:test';
import assert from 'node:assert/strict';
import { retryUndispatchedRunnerBusy } from './runner-recovery.mjs';
const busy = dispatched => Object.assign(new Error('runner refusal'), {
  details: { reason: 'runner_busy', dispatched, runnerErrorCode: 'RUNNER_BUSY' }
});
test('recovers only an explicit undispatched busy refusal with bounded delays', async () => {
  let calls = 0; const delays = [];
  const result = await retryUndispatchedRunnerBusy(async () => {
    if (++calls < 3) throw busy('no'); return 'done';
  }, async ms => delays.push(ms));
  assert.equal(result, 'done'); assert.equal(calls, 3); assert.deepEqual(delays, [3000, 8000]);
});
test('stops after three undispatched busy attempts', async () => {
  let calls = 0; const delays = [];
  await assert.rejects(retryUndispatchedRunnerBusy(async () => { calls++; throw busy('no'); }, async ms => delays.push(ms)));
  assert.equal(calls, 3); assert.deepEqual(delays, [3000, 8000]);
});
test('never repeats a potentially dispatched action', async () => {
  for (const dispatched of ['yes', 'unknown', undefined]) {
    let calls = 0;
    await assert.rejects(retryUndispatchedRunnerBusy(async () => { calls++; throw busy(dispatched); }, async () => assert.fail('must not retry')));
    assert.equal(calls, 1);
  }
});
test('does not retry application assertions or wait-deadline failures', async () => {
  let calls = 0;
  await assert.rejects(retryUndispatchedRunnerBusy(async () => {
    calls++; throw Object.assign(new Error('wait deadline'), { details: { reason: 'wait_deadline_exceeded', dispatched: 'no' } });
  }, async () => assert.fail('must not retry')));
  assert.equal(calls, 1);
});
