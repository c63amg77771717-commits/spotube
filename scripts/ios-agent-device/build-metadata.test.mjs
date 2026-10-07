import assert from 'node:assert/strict';
import test from 'node:test';
import { verifyInstalledAppMetadata } from './build-metadata.mjs';
const bundleID = 'com.c63amg77771717.evantube';
const build24 = { CFBundleIdentifier: bundleID, CFBundleVersion: '24', CFBundleShortVersionString: '1.0.0' };
test('accepts build24 when installed metadata matches the current product', () => {
  assert.equal(verifyInstalledAppMetadata(build24, { ...build24 }, bundleID).build, 24);
});
test('rejects a stale build23 installation', () => {
  assert.throws(() => verifyInstalledAppMetadata(build24, { ...build24, CFBundleVersion: '23' }, bundleID), /Installed build must match/);
});
test('rejects a wrong marketing version and bundle ID', () => {
  assert.throws(() => verifyInstalledAppMetadata(build24, { ...build24, CFBundleShortVersionString: '0.9.0' }, bundleID), /Installed marketing version/);
  assert.throws(() => verifyInstalledAppMetadata(build24, { ...build24, CFBundleIdentifier: 'other.app' }, bundleID), /Installed app must be/);
});
test('fails closed when the compiled build metadata is absent or malformed', () => {
  for (const version of [undefined, '', '0', '24oops', 24]) {
    assert.throws(() => verifyInstalledAppMetadata({ ...build24, CFBundleVersion: version }, build24, bundleID));
  }
});
test('can verify a later build without weakening exact comparison', () => {
  const later = { ...build24, CFBundleVersion: '25' };
  assert.equal(verifyInstalledAppMetadata(later, { ...later }, bundleID).build, 25);
  assert.throws(() => verifyInstalledAppMetadata(later, build24, bundleID), /Installed build must match/);
});
