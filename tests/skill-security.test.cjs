'use strict';

const assert = require('assert');
const childProcess = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const repositoryRoot = path.resolve(__dirname, '..');
const helper = path.join(repositoryRoot, 'skill-bridge.cjs');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'claudex-skill-security-'));
const skipped = [];

function write(file, contents) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, contents);
}

function createSkill(directory, name, body = 'Follow these instructions.') {
  write(path.join(directory, 'SKILL.md'), `---\nname: ${name}\ndescription: ${name} security test skill\n---\n\n${body}\n`);
}

function setup(name) {
  const root = path.join(temporary, name);
  const home = path.join(root, 'home');
  const config = path.join(home, '.config', 'claudex');
  const claudeHome = path.join(home, '.claude');
  const codexHome = path.join(home, '.codex');
  const repo = path.join(root, 'repo');
  const project = path.join(repo, 'app');
  const inventory = path.join(root, 'codex-plugins.json');
  fs.mkdirSync(path.join(repo, '.git'), { recursive: true });
  fs.mkdirSync(project, { recursive: true });
  write(inventory, '[]\n');
  return {
    root, home, config, claudeHome, codexHome, repo, project, inventory,
    environment: {
      ...process.env,
      HOME: home,
      USERPROFILE: home,
      CLAUDEX_CONFIG_DIR: config,
      CLAUDEX_CLAUDE_CONFIG_DIR: claudeHome,
      CODEX_HOME: codexHome,
      CLAUDEX_CODEX_ADMIN_SKILLS_DIR: path.join(root, 'missing-admin-skills'),
      CLAUDEX_TEST_CODEX_PLUGIN_LIST_FILE: inventory,
      CLAUDEX_SKILL_BRIDGE: 'on',
      CLAUDEX_SKILL_PLUGINS: 'on',
      CLAUDEX_SKILL_DOLLAR_REFERENCES: 'off',
      CLAUDEX_SKILL_EXTRA_DIRS: '',
    },
  };
}

function invoke(environment, project, timeout = 10000) {
  const result = childProcess.spawnSync(process.execPath, [helper, 'sync', '--project', project], {
    encoding: 'utf8', env: environment, maxBuffer: 16 * 1024 * 1024, timeout,
  });
  assert.strictEqual(result.error, undefined, result.error && result.error.message);
  assert.strictEqual(result.status, 0, result.stderr || result.stdout);
  return JSON.parse(result.stdout);
}

function aliases(result) {
  return new Set(result.skills.map((entry) => entry.alias));
}

function warningIncludes(result, fragment) {
  return result.warnings.some((warning) => warning.includes(fragment));
}

function testPlainScalarParsingIsBounded() {
  const probe = `
    const { codexSkillIdentity } = require(${JSON.stringify(helper)});
    const spaces = ' '.repeat(200000);
    const long = codexSkillIdentity('---\\nname: bounded-scalar\\ndescription: x' + spaces + 'y\\n---\\n');
    if (!long.valid || long.description.length !== spaces.length + 2) process.exit(2);
    const commented = codexSkillIdentity('---\\nname: comments\\ndescription: visible text   # ignored comment\\n---\\n');
    if (!commented.valid || commented.description !== 'visible text') process.exit(3);
  `;
  const result = childProcess.spawnSync(process.execPath, ['-e', probe], {
    encoding: 'utf8', timeout: 2000,
  });
  assert.strictEqual(result.error, undefined,
    `plain scalar parsing exceeded its bounded runtime: ${result.error && result.error.message}`);
  assert.strictEqual(result.status, 0, result.stderr || result.stdout);
}

function directorySymlink(target, link) {
  try {
    fs.mkdirSync(path.dirname(link), { recursive: true });
    fs.symlinkSync(target, link, process.platform === 'win32' ? 'junction' : 'dir');
    return true;
  } catch (error) {
    if (['EPERM', 'EACCES', 'ENOTSUP'].includes(error.code)) return false;
    throw error;
  }
}

function testProjectSymlinkEscape() {
  const fixture = setup('project-symlink');
  const outside = path.join(fixture.root, 'outside-project-skill');
  createSkill(outside, 'project-escape');
  write(path.join(outside, 'payload.txt'), 'must not cross the repository boundary\n');
  const link = path.join(fixture.repo, '.agents', 'skills', 'project-escape');
  if (!directorySymlink(outside, link)) {
    skipped.push('project symlink escape (symlinks unavailable)');
    return;
  }
  createSkill(path.join(fixture.home, '.agents', 'skills', 'safe-project-control'), 'safe-project-control');
  const result = invoke(fixture.environment, fixture.project);
  assert(aliases(result).has('safe-project-control'));
  assert(!aliases(result).has('project-escape'), 'a project skill symlink must not escape its repository');
  assert(warningIncludes(result, 'Ignored project skill symlink outside the repository'));
}

function testInternalSymlinkEscape() {
  const fixture = setup('internal-symlink');
  const source = path.join(fixture.home, '.agents', 'skills', 'internal-escape');
  const outside = path.join(fixture.root, 'outside-support-files');
  createSkill(source, 'internal-escape');
  write(path.join(outside, 'payload.txt'), 'outside support data\n');
  if (!directorySymlink(outside, path.join(source, 'assets', 'outside'))) {
    skipped.push('internal symlink escape (symlinks unavailable)');
    return;
  }
  createSkill(path.join(fixture.home, '.agents', 'skills', 'safe-internal-control'), 'safe-internal-control');
  const result = invoke(fixture.environment, fixture.project);
  assert(aliases(result).has('safe-internal-control'));
  assert(!aliases(result).has('internal-escape'), 'support-file symlinks must stay within the skill root');
  assert(warningIncludes(result, 'skill support symlink escapes its root'));
}

function testSensitiveFilesAndPrivateKeys() {
  const fixture = setup('sensitive-files');
  const envSkill = path.join(fixture.home, '.agents', 'skills', 'contains-env');
  const keySkill = path.join(fixture.home, '.agents', 'skills', 'contains-key');
  const lateKeySkill = path.join(fixture.home, '.agents', 'skills', 'contains-late-key');
  createSkill(envSkill, 'contains-env');
  write(path.join(envSkill, '.env'), 'SECRET_VALUE=do-not-copy\n');
  createSkill(keySkill, 'contains-key');
  write(path.join(keySkill, 'references', 'identity.txt'), '-----BEGIN PRIVATE KEY-----\nnot-a-real-key\n-----END PRIVATE KEY-----\n');
  createSkill(lateKeySkill, 'contains-late-key');
  write(path.join(lateKeySkill, 'references', 'late-identity.txt'), `${'x'.repeat(1024 * 1024 + 1)}\n-----BEGIN PRIVATE KEY-----\nnot-a-real-key\n`);
  createSkill(path.join(fixture.home, '.agents', 'skills', 'safe-sensitive-control'), 'safe-sensitive-control');

  const result = invoke(fixture.environment, fixture.project);
  const names = aliases(result);
  assert(names.has('safe-sensitive-control'));
  assert(!names.has('contains-env'), 'skills containing environment files must be rejected');
  assert(!names.has('contains-key'), 'skills containing private-key material must be rejected');
  assert(!names.has('contains-late-key'), 'private-key material after the first MiB must still be rejected');
  assert(warningIncludes(result, 'skill tree contains a sensitive file: .env'));
  assert(warningIncludes(result, 'skill tree contains private-key material: references'));
  assert(!result.warnings.join('\n').includes('do-not-copy'), 'warnings must not disclose rejected secret contents');
}

function testCorruptGenerationSelfHealing() {
  const fixture = setup('corrupt-generation');
  createSkill(path.join(fixture.home, '.agents', 'skills', 'self-healing'), 'self-healing');
  const first = invoke(fixture.environment, fixture.project);
  const published = path.join(first.overlay, '.claude', 'skills', 'self-healing', 'SKILL.md');
  fs.unlinkSync(published);

  const repaired = invoke(fixture.environment, fixture.project);
  assert.strictEqual(repaired.overlay, first.overlay, 'content-addressed repair should restore the expected generation path');
  assert(fs.existsSync(published), 'a structurally incomplete generation must be rebuilt before reuse');
  assert(aliases(repaired).has('self-healing'));
}

function testPolicyAwareCacheAndFallback() {
  const fixture = setup('policy-aware-cache');
  const source = path.join(fixture.home, '.agents', 'skills', 'policy-cache');
  const asset = path.join(source, 'asset.txt');
  createSkill(source, 'policy-cache');
  write(asset, 'policy version one\n');
  const enabled = invoke({ ...fixture.environment, CLAUDEX_SKILL_PLUGINS: 'on' }, fixture.project);
  const disabled = invoke({ ...fixture.environment, CLAUDEX_SKILL_PLUGINS: 'off' }, fixture.project);
  assert.notStrictEqual(disabled.overlay, enabled.overlay,
    'generations with different bridge policy fingerprints must not share a manifest');
  const disabledManifest = JSON.parse(fs.readFileSync(path.join(disabled.overlay, 'manifest.json'), 'utf8'));
  const pointers = fs.readdirSync(path.join(fixture.config, 'skill-bridge', 'generations'))
    .filter((entry) => entry.startsWith('.latest-'));
  const disabledPointer = pointers.map((entry) => ({
    entry,
    value: JSON.parse(fs.readFileSync(path.join(fixture.config, 'skill-bridge', 'generations', entry), 'utf8')),
  })).find(({ value }) => value.generation === path.basename(disabled.overlay));
  assert(disabledPointer && disabledPointer.entry.includes(disabledManifest.policyFingerprint));

  write(asset, 'publication should fail under disabled plugin policy\n');
  const fallback = invoke({
    ...fixture.environment,
    CLAUDEX_SKILL_PLUGINS: 'off',
    NODE_ENV: 'test',
    CLAUDEX_TEST_FAIL_SKILL_PUBLICATION: '1',
  }, fixture.project);
  assert.strictEqual(fallback.overlay, disabled.overlay, 'policy-matched LKG must survive a failed refresh');
  assert(warningIncludes(fallback, 'Skill refresh failed; using the last known good snapshot'));
}

function testFreshWarningsOnCacheHits() {
  const fixture = setup('fresh-cache-warnings');
  createSkill(path.join(fixture.home, '.agents', 'skills', 'warning-control'), 'warning-control');
  write(fixture.inventory, '[]\n');
  const clean = invoke(fixture.environment, fixture.project);
  assert.strictEqual(clean.warnings.length, 0);

  write(fixture.inventory, '[null]\n');
  const malformed = invoke(fixture.environment, fixture.project);
  assert.strictEqual(malformed.overlay, clean.overlay, 'diagnostic-only changes should reuse immutable content');
  assert(warningIncludes(malformed, 'Ignored malformed Codex plugin record'));

  write(fixture.inventory, '[]\n');
  const repaired = invoke(fixture.environment, fixture.project);
  assert.strictEqual(repaired.overlay, clean.overlay);
  assert(!warningIncludes(repaired, 'Ignored malformed Codex plugin record'), 'resolved discovery warnings must not persist from the manifest');
}

function testBoundedGenerationAndStageRetention() {
  const fixture = setup('bounded-retention');
  const source = path.join(fixture.home, '.agents', 'skills', 'changing');
  for (let revision = 0; revision < 12; revision++) {
    createSkill(source, 'changing', `revision ${revision}`);
    invoke(fixture.environment, fixture.project);
  }
  const generations = path.join(fixture.config, 'skill-bridge', 'generations');
  const published = fs.readdirSync(generations, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && !entry.name.startsWith('.'));
  assert(published.length <= 8, `generation retention exceeded the hard cap: ${published.length}`);

  for (let index = 0; index < 12; index++) fs.mkdirSync(path.join(generations, `.stage-fixture-${index}`));
  invoke(fixture.environment, fixture.project);
  const stages = fs.readdirSync(generations, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && entry.name.startsWith('.stage-'));
  assert(stages.length <= 8, `stage retention exceeded the hard cap: ${stages.length}`);
}

function testSpecialFileHandling() {
  if (process.platform === 'win32') {
    skipped.push('FIFO rejection (not portable to Windows)');
    return;
  }
  const fixture = setup('special-file');
  const source = path.join(fixture.home, '.agents', 'skills', 'contains-fifo');
  createSkill(source, 'contains-fifo');
  const fifo = path.join(source, 'events.pipe');
  const made = childProcess.spawnSync('mkfifo', [fifo], { encoding: 'utf8' });
  if (made.error && made.error.code === 'ENOENT') {
    skipped.push('FIFO rejection (mkfifo unavailable)');
    return;
  }
  assert.strictEqual(made.status, 0, made.stderr || (made.error && made.error.message));
  createSkill(path.join(fixture.home, '.agents', 'skills', 'safe-fifo-control'), 'safe-fifo-control');
  const result = invoke(fixture.environment, fixture.project, 5000);
  assert(aliases(result).has('safe-fifo-control'));
  assert(!aliases(result).has('contains-fifo'), 'special files must be rejected without blocking on reads');
  assert(warningIncludes(result, 'skill tree contains unsupported file type: events.pipe'));
}

function testMalformedPluginInventories() {
  const fixture = setup('malformed-inventories');
  createSkill(path.join(fixture.home, '.agents', 'skills', 'inventory-control'), 'inventory-control');
  write(path.join(fixture.claudeHome, 'plugins', 'installed_plugins.json'), JSON.stringify({
    version: 2,
    plugins: {
      'broken@market': [null, 7, 'not-an-install'],
      'not-a-list@market': { installPath: fixture.root },
    },
  }));
  write(fixture.inventory, JSON.stringify([null, 4, 'not-a-plugin', { enabled: false }]));

  const result = invoke(fixture.environment, fixture.project);
  assert(aliases(result).has('inventory-control'), 'malformed plugin records must not prevent standalone skill discovery');
  assert(result.warnings.filter((warning) => warning.includes('Ignored malformed Claude plugin record')).length >= 3);
  assert(result.warnings.filter((warning) => warning.includes('Ignored malformed Codex plugin record')).length >= 3);
}

function testImmutableSnapshotsAndFullTreeFingerprint() {
  const fixture = setup('immutable-snapshots');
  const source = path.join(fixture.home, '.agents', 'skills', 'snapshot-tree');
  createSkill(source, 'snapshot-tree');
  const sourceAsset = path.join(source, 'assets', 'value.txt');
  write(sourceAsset, 'version one\n');

  const first = invoke(fixture.environment, fixture.project);
  const firstSkill = path.join(first.overlay, '.claude', 'skills', 'snapshot-tree');
  const firstAsset = path.join(firstSkill, 'assets', 'value.txt');
  assert.strictEqual(fs.readFileSync(firstAsset, 'utf8'), 'version one\n');
  assert(!fs.lstatSync(firstAsset).isSymbolicLink(), 'published support files must be immutable copies, not live symlinks');

  write(sourceAsset, 'version two\n');
  write(path.join(source, 'references', 'new-file.md'), 'A newly added support file.\n');
  assert.strictEqual(fs.readFileSync(firstAsset, 'utf8'), 'version one\n', 'source mutation must not alter an existing snapshot');

  const second = invoke(fixture.environment, fixture.project);
  assert.notStrictEqual(second.overlay, first.overlay, 'support-tree changes must refresh the generation fingerprint');
  const secondSkill = path.join(second.overlay, '.claude', 'skills', 'snapshot-tree');
  assert.strictEqual(fs.readFileSync(path.join(secondSkill, 'assets', 'value.txt'), 'utf8'), 'version two\n');
  assert.strictEqual(fs.readFileSync(path.join(secondSkill, 'references', 'new-file.md'), 'utf8'), 'A newly added support file.\n');
  assert.strictEqual(fs.readFileSync(firstAsset, 'utf8'), 'version one\n', 'new publication must leave prior snapshots unchanged');
  assert(!fs.existsSync(path.join(firstSkill, 'references', 'new-file.md')));
}

function testNativeConfigCollisionReservation() {
  const fixture = setup('native-collision');
  createSkill(path.join(fixture.config, 'skills', 'reserved'), 'reserved');
  createSkill(path.join(fixture.claudeHome, 'skills', 'reserved'), 'reserved');
  const result = invoke(fixture.environment, fixture.project);
  const names = aliases(result);
  assert(!names.has('reserved'), 'the isolated Claudex config must reserve its native unqualified alias');
  assert(names.has('claude-reserved'), 'the bridged collision must receive a provider-qualified alias');
  const record = result.skills.find((entry) => entry.alias === 'claude-reserved');
  assert(record && record.collisionAlias === true);
}

function testNativePluginNamespaceReservation() {
  const fixture = setup('native-plugin-collision');
  const nativePlugin = path.join(fixture.config, 'plugins', 'cache', 'native', 'shared', '1.0.0');
  write(path.join(nativePlugin, '.claude-plugin', 'plugin.json'), '{"name":"shared"}\n');
  write(path.join(fixture.config, 'plugins', 'installed_plugins.json'), JSON.stringify({
    plugins: { 'shared@native': [{ scope: 'user', installPath: nativePlugin }] },
  }));

  const importedPlugin = path.join(fixture.codexHome, 'plugins', 'cache', 'market', 'shared', '2.0.0');
  write(path.join(importedPlugin, '.codex-plugin', 'plugin.json'), '{"name":"shared","skills":["skills"]}\n');
  createSkill(path.join(importedPlugin, 'skills', 'task'), 'task');
  write(fixture.inventory, JSON.stringify({ installed: [{
    pluginId: 'shared@market', name: 'shared', marketplaceName: 'market',
    version: '2.0.0', installed: true, enabled: true,
  }] }));

  const result = invoke(fixture.environment, fixture.project);
  assert(result.skills.some((entry) => entry.alias === 'imported-shared:task'),
    'an imported plugin must be qualified when its namespace is already native');
  assert(!result.skills.some((entry) => entry.alias === 'shared:task'),
    'an imported plugin must not shadow a native Claudex plugin namespace');
}

function testLastKnownGoodFallback() {
  const fixture = setup('last-known-good');
  const source = path.join(fixture.home, '.agents', 'skills', 'fallback-tree');
  const asset = path.join(source, 'assets', 'value.txt');
  createSkill(source, 'fallback-tree');
  write(asset, 'known good one\n');
  const first = invoke(fixture.environment, fixture.project);
  write(asset, 'known good two\n');
  const newest = invoke(fixture.environment, fixture.project);
  fs.utimesSync(newest.overlay, new Date(), new Date(Date.now() + 2000));
  const firstManifest = JSON.parse(fs.readFileSync(path.join(first.overlay, 'manifest.json'), 'utf8'));
  const newestManifest = JSON.parse(fs.readFileSync(path.join(newest.overlay, 'manifest.json'), 'utf8'));
  assert.strictEqual(newestManifest.policyFingerprint, firstManifest.policyFingerprint,
    'source content changes must not change the skill policy fingerprint');
  const generations = path.join(fixture.config, 'skill-bridge', 'generations');
  const pointers = fs.readdirSync(generations).filter((entry) => entry.startsWith('.latest-'));
  assert.strictEqual(pointers.length, 1, 'one policy-stable latest-generation pointer must be recorded');
  const pointer = JSON.parse(fs.readFileSync(path.join(generations, pointers[0]), 'utf8'));
  assert.strictEqual(pointer.generation, path.basename(newest.overlay),
    'the latest-generation pointer must be replaced after every successful publication');

  write(asset, 'publication should fail\n');
  const fallback = invoke({
    ...fixture.environment,
    NODE_ENV: 'test',
    CLAUDEX_TEST_FAIL_SKILL_PUBLICATION: '1',
  }, fixture.project);
  assert.strictEqual(fallback.overlay, newest.overlay, 'publication failure must return the newest valid snapshot');
  assert(warningIncludes(fallback, 'Skill refresh failed; using the last known good snapshot'));
  const publishedAsset = path.join(fallback.overlay, '.claude', 'skills', 'fallback-tree', 'assets', 'value.txt');
  assert.strictEqual(fs.readFileSync(publishedAsset, 'utf8'), 'known good two\n');
}

try {
  testPlainScalarParsingIsBounded();
  testProjectSymlinkEscape();
  testInternalSymlinkEscape();
  testSensitiveFilesAndPrivateKeys();
  testSpecialFileHandling();
  testMalformedPluginInventories();
  testImmutableSnapshotsAndFullTreeFingerprint();
  testCorruptGenerationSelfHealing();
  testPolicyAwareCacheAndFallback();
  testFreshWarningsOnCacheHits();
  testBoundedGenerationAndStageRetention();
  testNativeConfigCollisionReservation();
  testNativePluginNamespaceReservation();
  testLastKnownGoodFallback();
  process.stdout.write(`skill security tests passed${skipped.length ? ` (${skipped.join('; ')})` : ''}\n`);
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
