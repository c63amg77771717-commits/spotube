import assert from 'node:assert/strict';

// Compare the installed app with this checkout's actual compiled simulator product.
// A changed build number must update the build product, never weaken this guard.
export function verifyInstalledAppMetadata(expected, installed, bundleID) {
  assert.equal(expected.CFBundleIdentifier, bundleID, 'Built product must be EvanTube');
  assert.equal(installed.CFBundleIdentifier, bundleID, 'Installed app must be EvanTube');
  const expectedBuild = expected.CFBundleVersion;
  assert.equal(typeof expectedBuild, 'string', 'Built product needs a string build number');
  assert.match(expectedBuild, /^[1-9]\d*$/, 'Built product needs a positive integer build number');
  assert.equal(installed.CFBundleVersion, expectedBuild,
    'Installed build must match this commit\'s compiled product');
  assert.equal(typeof expected.CFBundleShortVersionString, 'string', 'Built product needs a marketing version');
  assert(expected.CFBundleShortVersionString.length > 0, 'Built product marketing version cannot be empty');
  assert.equal(installed.CFBundleShortVersionString, expected.CFBundleShortVersionString,
    'Installed marketing version must match this commit\'s compiled product');
  return { build: Number(expectedBuild), marketingVersion: expected.CFBundleShortVersionString,
    bundleIdentifier: bundleID };
}
