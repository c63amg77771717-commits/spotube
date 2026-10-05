import assert from 'node:assert/strict';

function uniqueActionable(nodes, description) {
  assert.equal(nodes.length, 1, `${description} must match exactly one element, found ${nodes.length}`);
  const node = nodes[0];
  assert(node.enabled && node.hittable, `${description} must be enabled and hittable`);
  assert(node.rect && ['x', 'y', 'width', 'height'].every(key => Number.isFinite(node.rect[key])),
    `${description} must have finite current snapshot geometry`);
  assert(node.rect.width > 0 && node.rect.height > 0, `${description} must have nonempty geometry`);
  return node;
}

export function fullPlayerProgress(snapshot) {
  return uniqueActionable(snapshot.nodes.filter(node => /^Progress: \d+:\d+ of /.test(node.label ?? '')),
    'Full player progress');
}

export function fullPlayerButton(snapshot, label) {
  return uniqueActionable(snapshot.nodes.filter(node => node.kind === 'button' && node.label === label &&
    !node.identifier?.startsWith('dock_')), `Full player ${label} button`);
}

export function currentRef(snapshot, node) {
  assert(node.ref, 'Actionable snapshot node must have a reference');
  const ref = node.ref.startsWith('@') ? node.ref : `@${node.ref}`;
  return snapshot.refsGeneration ? `${ref}~s${snapshot.refsGeneration}` : ref;
}
