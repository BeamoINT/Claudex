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
  const gitCredentialSkill = path.join(fixture.home, '.agents', 'skills', 'contains-git-credentials');
  const cliCredentialSkill = path.join(fixture.home, '.agents', 'skills', 'contains-cli-credentials');
  createSkill(envSkill, 'contains-env');
  write(path.join(envSkill, '.env'), 'SECRET_VALUE=do-not-copy\n');
  createSkill(keySkill, 'contains-key');
  write(path.join(keySkill, 'references', 'identity.txt'), '-----BEGIN PRIVATE KEY-----\nnot-a-real-key\n-----END PRIVATE KEY-----\n');
  createSkill(lateKeySkill, 'contains-late-key');
  write(path.join(lateKeySkill, 'references', 'late-identity.txt'), `${'x'.repeat(1024 * 1024 + 1)}\n-----BEGIN PRIVATE KEY-----\nnot-a-real-key\n`);
  createSkill(gitCredentialSkill, 'contains-git-credentials');
  write(path.join(gitCredentialSkill, '.git-credentials'), 'https://user:secret@example.invalid\n');
  createSkill(cliCredentialSkill, 'contains-cli-credentials');
  write(path.join(cliCredentialSkill, '.config', 'gh', 'hosts.yml'), 'github.com:\n  oauth_token: secret\n');
  createSkill(path.join(fixture.home, '.agents', 'skills', 'safe-sensitive-control'), 'safe-sensitive-control');

  const result = invoke(fixture.environment, fixture.project);
  const names = aliases(result);
  assert(names.has('safe-sensitive-control'));
  assert(!names.has('contains-env'), 'skills containing environment files must be rejected');
  assert(!names.has('contains-key'), 'skills containing material that resembles a private key must be rejected');
  assert(!names.has('contains-late-key'), 'private key material after the first MiB must still be rejected');
  assert(!names.has('contains-git-credentials'), '.git-credentials must never be copied into a snapshot');
  assert(!names.has('contains-cli-credentials'), 'CLI credential stores must never be copied into a snapshot');
  assert(warningIncludes(result, 'skill tree contains a sensitive file: .env'));
  assert(warningIncludes(result, 'skill tree contains a sensitive file: .git-credentials'));
  assert(warningIncludes(result, 'skill tree contains a sensitive file: .config'));
  assert(warningIncludes(result, 'skill tree contains material that resembles a private key: references'));
  assert(!result.warnings.join('\n').includes('do-not-copy'), 'warnings must not disclose rejected secret contents');
}

function testCorruptGenerationSelfHealing() {
  const fixture = setup('corrupt-generation');
  createSkill(path.join(fixture.home, '.agents', 'skills', 'self-healing'), 'self-healing');
  const first = invoke(fixture.environment, fixture.project);
  const published = path.join(first.overlay, '.claude', 'skills', 'self-healing', 'SKILL.md');
  write(published, '---\nname: self-healing\ndescription: tampered\n---\n\nTAMPERED_CACHE_CONTENT\n');

  const repaired = invoke(fixture.environment, fixture.project);
  assert.strictEqual(repaired.overlay, first.overlay, 'content-addressed repair should restore the expected generation path');
  assert(!fs.readFileSync(published, 'utf8').includes('TAMPERED_CACHE_CONTENT'),
    'cache content tampering must be detected and rebuilt before reuse');
  assert(aliases(repaired).has('self-healing'));
}

function testPluginInternalSymlinkAndManagedSideloadPolicy() {
  const fixture = setup('plugin-symlink-policy');
  const plugin = path.join(fixture.codexHome, 'plugins', 'cache', 'market', 'linked-plugin', '1.0.0');
  write(path.join(plugin, '.codex-plugin', 'plugin.json'), '{"name":"linked-plugin","skills":["skills"]}\n');
  createSkill(path.join(plugin, 'skills', 'linked-task'), 'linked-task', 'Read assets/shared/info.txt.');
  write(path.join(plugin, 'shared', 'info.txt'), 'PLUGIN_INTERNAL_SYMLINK_MARKER\n');
  if (!directorySymlink(path.join(plugin, 'shared'), path.join(plugin, 'skills', 'linked-task', 'assets', 'shared'))) {
    skipped.push('plugin internal symlink (symlinks unavailable)');
    return;
  }
  write(fixture.inventory, JSON.stringify({ installed: [{
    pluginId: 'linked-plugin@market', name: 'linked-plugin', marketplaceName: 'market',
    version: '1.0.0', installed: true, enabled: true,
  }] }));
  const bridged = invoke(fixture.environment, fixture.project);
  const linked = bridged.pluginDirs.find((directory) => fs.existsSync(path.join(directory, 'skills', 'linked-task', 'SKILL.md')));
  assert(linked, 'a plugin skill with an internal plugin-bounded symlink was not imported');
  assert.strictEqual(fs.readFileSync(path.join(linked, 'skills', 'linked-task', 'assets', 'shared', 'info.txt'), 'utf8'),
    'PLUGIN_INTERNAL_SYMLINK_MARKER\n');

  const managed = path.join(fixture.root, 'managed-settings.json');
  write(managed, '{"disableSideloadFlags":false}\n');
  write(path.join(fixture.root, 'managed-settings.d', '99-lockdown.json'), '{"disableSideloadFlags":true}\n');
  createSkill(path.join(fixture.home, '.agents', 'skills', 'standalone-control'), 'standalone-control');
  const restricted = invoke({ ...fixture.environment, CLAUDEX_CLAUDE_MANAGED_SETTINGS_FILE: managed }, fixture.project);
  assert.deepStrictEqual(restricted.pluginDirs, [], 'managed disableSideloadFlags must emit no generated --plugin-dir values');
  assert(aliases(restricted).has('standalone-control'), 'standalone --add-dir skill compatibility should remain available');
  assert(!aliases(restricted).has('linked-plugin:linked-task'));
  assert(warningIncludes(restricted, 'disable --plugin-dir sideloading'));
}

function testStrictPluginOnlySkillPolicy() {
  const fixture = setup('strict-plugin-only-skills');
  createSkill(path.join(fixture.home, '.agents', 'skills', 'standalone-strict'), 'standalone-strict');
  write(path.join(fixture.claudeHome, 'commands', 'standalone-command.md'),
    '---\ndescription: standalone command\n---\n\nSTANDALONE_COMMAND_BODY\n');
  const plugin = path.join(fixture.codexHome, 'plugins', 'cache', 'market', 'strict-plugin', '1.0.0');
  write(path.join(plugin, '.codex-plugin', 'plugin.json'), '{"name":"strict-plugin","skills":["skills"]}\n');
  createSkill(path.join(plugin, 'skills', 'plugin-task'), 'plugin-task');
  write(fixture.inventory, JSON.stringify({ installed: [{
    pluginId: 'strict-plugin@market', name: 'strict-plugin', marketplaceName: 'market',
    version: '1.0.0', installed: true, enabled: true,
  }] }));
  write(path.join(fixture.repo, '.claude', 'settings.local.json'), '{"strictPluginOnlyCustomization":false}\n');
  const managed = path.join(fixture.root, 'managed-settings.json');
  write(managed, '{"strictPluginOnlyCustomization":true}\n');
  const strictBoolean = invoke({ ...fixture.environment, CLAUDEX_CLAUDE_MANAGED_SETTINGS_FILE: managed }, fixture.project);
  assert(!aliases(strictBoolean).has('standalone-strict'), 'managed strict plugin-only policy must omit standalone skills');
  assert(!aliases(strictBoolean).has('standalone-command'), 'boolean strict plugin-only policy must omit standalone commands');
  assert(aliases(strictBoolean).has('strict-plugin:plugin-task'), 'strict plugin-only policy must retain plugin skills');
  assert(warningIncludes(strictBoolean, 'require skills to come from plugins'));

  write(managed, '{"strictPluginOnlyCustomization":["skills"]}\n');
  const strictArray = invoke({ ...fixture.environment, CLAUDEX_CLAUDE_MANAGED_SETTINGS_FILE: managed }, fixture.project);
  assert(!aliases(strictArray).has('standalone-strict'));
  assert(aliases(strictArray).has('standalone-command'), 'skills strict category must not block standalone commands');
  assert(aliases(strictArray).has('strict-plugin:plugin-task'));

  write(managed, '{"strictPluginOnlyCustomization":["commands"]}\n');
  const commandsOnly = invoke({ ...fixture.environment, CLAUDEX_CLAUDE_MANAGED_SETTINGS_FILE: managed }, fixture.project);
  assert(aliases(commandsOnly).has('standalone-strict'), 'non-skill strict categories must not block standalone skills');
  assert(!aliases(commandsOnly).has('standalone-command'), 'commands strict category must omit standalone Claude commands');
  assert(aliases(commandsOnly).has('strict-plugin:plugin-task'), 'commands strict category must retain plugin customizations');
  assert(warningIncludes(commandsOnly, 'require commands to come from plugins'));
}

function testCodexConfigTrustAndReenablePrecedence() {
  const fixture = setup('codex-config-trust');
  const skillRoot = path.join(fixture.repo, '.agents', 'skills', 'reenabled');
  createSkill(skillRoot, 'reenabled');
  write(path.join(fixture.codexHome, 'config.toml'), [
    '[["skills"."config"]]',
    `"path" = ${JSON.stringify(skillRoot)}`,
    '"enabled" = false',
    '',
  ].join('\n'));
  write(path.join(fixture.repo, '.codex', 'config.toml'), [
    '[[skills.config]]',
    `path = ${JSON.stringify(skillRoot)}`,
    'enabled = true',
    '',
  ].join('\n'));
  assert(aliases(invoke(fixture.environment, fixture.project)).has('reenabled'),
    'the closest enabled=true entry must re-enable a lower-precedence disabled skill');

  write(path.join(fixture.codexHome, 'config.toml'), [
    `[projects.${JSON.stringify(fixture.repo)}]`,
    'trust_level = "untrusted"',
    '',
  ].join('\n'));
  write(path.join(fixture.repo, '.codex', 'config.toml'), [
    '[[skills.config]]',
    `path = ${JSON.stringify(skillRoot)}`,
    'enabled = false',
    '',
  ].join('\n'));
  assert(aliases(invoke(fixture.environment, fixture.project)).has('reenabled'),
    'untrusted project .codex/config.toml must not affect bridge policy');
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

function testInstructionPolicyAwareFallback() {
  const fixture = setup('instruction-policy-aware-fallback');
  write(path.join(fixture.repo, 'AGENTS.md'), `INSTRUCTION_POLICY_MARKER\n${'x'.repeat(1024)}\n`);
  const config = path.join(fixture.codexHome, 'config.toml');
  write(config, 'project_doc_max_bytes = 65536\nproject_doc_fallback_filenames = ["TEAM.md"]\n');
  const permissive = invoke(fixture.environment, fixture.project);
  assert(fs.readFileSync(path.join(permissive.overlay, 'CLAUDE.md')).length > 16);

  write(config, 'project_doc_max_bytes = 16\nproject_doc_fallback_filenames = ["TEAM.md"]\n');
  const failed = childProcess.spawnSync(process.execPath, [helper, 'sync', '--project', fixture.project], {
    encoding: 'utf8',
    env: { ...fixture.environment, NODE_ENV: 'test', CLAUDEX_TEST_FAIL_SKILL_PUBLICATION: '1' },
    maxBuffer: 16 * 1024 * 1024,
  });
  assert.notStrictEqual(failed.status, 0,
    'a snapshot from a different instruction policy must not be used as last-known-good fallback');

  const restricted = invoke(fixture.environment, fixture.project);
  assert(fs.readFileSync(path.join(restricted.overlay, 'CLAUDE.md')).length <= 16,
    'tightened instruction budget was not applied after rejected fallback');
  const permissiveManifest = JSON.parse(fs.readFileSync(path.join(permissive.overlay, 'manifest.json'), 'utf8'));
  const restrictedManifest = JSON.parse(fs.readFileSync(path.join(restricted.overlay, 'manifest.json'), 'utf8'));
  assert.notStrictEqual(restrictedManifest.policyFingerprint, permissiveManifest.policyFingerprint,
    'instruction policy inputs must participate in the LKG policy fingerprint');
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
  const malformedClaudePlugin = path.join(fixture.claudeHome, 'plugins', 'cache', 'market', 'bad-manifest', '1.0.0');
  write(path.join(malformedClaudePlugin, '.claude-plugin', 'plugin.json'), '{ invalid json');
  createSkill(path.join(malformedClaudePlugin, 'skills', 'must-not-load'), 'must-not-load');
  const malformedCodexPlugin = path.join(fixture.codexHome, 'plugins', 'cache', 'market', 'bad-codex-manifest', '1.0.0');
  write(path.join(malformedCodexPlugin, '.codex-plugin', 'plugin.json'), '[]\n');
  createSkill(path.join(malformedCodexPlugin, 'skills', 'must-not-load-codex'), 'must-not-load-codex');
  const bidiPlugin = path.join(fixture.claudeHome, 'plugins', 'cache', 'market', 'bidi-plugin', '1.0.0');
  write(path.join(bidiPlugin, '.claude-plugin', 'plugin.json'), JSON.stringify({
    name: 'bidi-plugin', skills: './\u202e/../../outside',
  }));
  write(path.join(fixture.claudeHome, 'plugins', 'installed_plugins.json'), JSON.stringify({
    version: 2,
    plugins: {
      'broken@market': [null, 7, 'not-an-install'],
      'not-a-list@market': { installPath: fixture.root },
      'bad-manifest@market': [{ scope: 'user', installPath: malformedClaudePlugin }],
      'bidi-plugin@market': [{ scope: 'user', installPath: bidiPlugin }],
    },
  }));
  write(fixture.inventory, JSON.stringify([
    null, 4, 'not-a-plugin', { enabled: false },
    {
      pluginId: 'bad-codex-manifest@market', name: 'bad-codex-manifest', marketplaceName: 'market',
      version: '1.0.0', installed: true, enabled: true,
    },
  ]));

  const result = invoke(fixture.environment, fixture.project);
  assert(aliases(result).has('inventory-control'), 'malformed plugin records must not prevent standalone skill discovery');
  assert(!aliases(result).has('bad-manifest:must-not-load'),
    'a malformed Claude plugin manifest must not fall back to default skill roots');
  assert(!aliases(result).has('bad-codex-manifest:must-not-load-codex'),
    'a malformed Codex plugin manifest must not fall back to default skill roots');
  assert.strictEqual(result.warnings.filter((warning) => warning.includes('Ignored malformed Claude plugin record')).length, 1,
    'repeated Claude inventory warnings must be deduplicated');
  assert.strictEqual(result.warnings.filter((warning) => warning.includes('Ignored malformed Codex plugin record')).length, 1,
    'repeated Codex inventory warnings must be deduplicated');
  assert(result.warnings.some((warning) => warning.includes('Ignored malformed plugin manifest')),
    'malformed plugin manifests must produce an explicit diagnostic');
  assert(!result.warnings.join('\n').includes('\u202e'), 'warning output must strip Unicode bidi controls');
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

function testManagedPersonalProjectPrecedence() {
  const fixture = setup('managed-personal-project-precedence');
  createSkill(path.join(fixture.claudeHome, 'skills', 'personal-wins'), 'personal-wins');
  createSkill(path.join(fixture.repo, '.claude', 'skills', 'personal-wins'), 'personal-wins');
  const personal = invoke(fixture.environment, fixture.project);
  assert(aliases(personal).has('personal-wins'), 'personal Claude skills must retain the short alias over project skills');

  const managedSkills = path.join(fixture.root, 'managed', 'skills');
  createSkill(path.join(managedSkills, 'managed-wins'), 'managed-wins');
  createSkill(path.join(fixture.claudeHome, 'skills', 'managed-wins'), 'managed-wins');
  createSkill(path.join(fixture.repo, '.claude', 'skills', 'managed-wins'), 'managed-wins');
  const managed = invoke({ ...fixture.environment, CLAUDEX_CLAUDE_MANAGED_SKILLS_DIR: managedSkills }, fixture.project);
  assert(!aliases(managed).has('managed-wins'), 'personal skill must not claim a managed skill short alias');
  assert(aliases(managed).has('claude-managed-wins'), 'managed collision must retain an explicit personal fallback alias');
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
  testPluginInternalSymlinkAndManagedSideloadPolicy();
  testStrictPluginOnlySkillPolicy();
  testCodexConfigTrustAndReenablePrecedence();
  testPolicyAwareCacheAndFallback();
  testInstructionPolicyAwareFallback();
  testFreshWarningsOnCacheHits();
  testBoundedGenerationAndStageRetention();
  testNativeConfigCollisionReservation();
  testManagedPersonalProjectPrecedence();
  testNativePluginNamespaceReservation();
  testLastKnownGoodFallback();
  process.stdout.write(`skill security tests passed${skipped.length ? ` (${skipped.join('; ')})` : ''}\n`);
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
