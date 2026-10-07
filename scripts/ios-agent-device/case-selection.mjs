import assert from 'node:assert/strict';

// A scoped acceptance run keeps the original case body and every assertion.
// Cases omitted by an explicit diagnostic request never count as passes.
export function selectAcceptanceCases(cases, requested = 'all') {
  const filter = requested || 'all';
  if (filter === 'all') return cases;
  assert.equal(filter, 'plain-candidate-and-relaunch', 'Unknown acceptance case; refusing an empty or broadened run');
  const selected = cases.filter(([name]) => name === filter);
  assert.equal(selected.length, 1, 'The requested original acceptance case must exist exactly once');
  return selected;
}
