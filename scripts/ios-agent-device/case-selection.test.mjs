import test from 'node:test';
import assert from 'node:assert/strict';
import { selectAcceptanceCases } from './case-selection.mjs';

const selectedAction = () => {};
const cases = [['plain-candidate-and-relaunch', { candidates: true }, selectedAction],
  ['cross-provider-setting-and-memory', { sources: true }, () => {}]];

test('ordinary runs preserve the complete suite and original entries', () => {
  assert.equal(selectAcceptanceCases(cases), cases);
  assert.equal(selectAcceptanceCases(cases, 'all'), cases);
});
test('scoped retry retains the exact original case config and function', () => {
  const scoped = selectAcceptanceCases(cases, 'plain-candidate-and-relaunch');
  assert.equal(scoped.length, 1);
  assert.equal(scoped[0], cases[0]);
  assert.equal(scoped[0][2], selectedAction);
});
test('invalid or ambiguous scope fails instead of producing misleading green evidence', () => {
  assert.throws(() => selectAcceptanceCases(cases, 'unknown'));
  assert.throws(() => selectAcceptanceCases([], 'plain-candidate-and-relaunch'));
  assert.throws(() => selectAcceptanceCases([cases[0], cases[0]], 'plain-candidate-and-relaunch'));
});
