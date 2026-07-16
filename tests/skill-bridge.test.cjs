'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const childProcess = require('child_process');
const crypto = require('crypto');

const root = path.resolve(__dirname, '..');
const helper = path.join(root, 'skill-bridge.cjs');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'claudex-skill-bridge-'));

function write(file, contents) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, contents);
}

function skill(directory, name, body = 'Follow this skill.') {
  write(path.join(directory, 'SKILL.md'), `---\nname: ${name}\ndescription: ${name} test skill\n---\n\n${body}\n`);
}

function digest(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function invoke(command, environment, cwd) {
  const result = childProcess.spawnSync(process.execPath, [helper, command, '--project', cwd], {
    encoding: 'utf8', env: { ...process.env, ...environment }, maxBuffer: 16 * 1024 * 1024,
  });
  assert.strictEqual(result.status, 0, result.stderr || result.stdout);
  return command === 'sync' ? JSON.parse(result.stdout) : result.stdout;
}

try {
  const home = path.join(temporary, 'home with spaces');
  const config = path.join(home, '.config', 'claudex');
  const claudeHome = path.join(home, '.claude');
  const codexHome = path.join(home, '.codex');
  const repo = path.join(temporary, 'repo');
  const project = path.join(repo, 'packages', 'web');
  fs.mkdirSync(path.join(repo, '.git'), { recursive: true });
  fs.mkdirSync(project, { recursive: true });

  const claudeAlpha = path.join(claudeHome, 'skills', 'alpha');
  skill(claudeAlpha, 'alpha', 'Use the bundled asset.');
  write(path.join(claudeAlpha, 'assets', 'sample.txt'), 'alpha asset\n');
  write(path.join(claudeAlpha, 'SKILL.md'), '---\nname: alpha\ndescription: Claude alpha\nmodel: claude-sonnet-9-9\n---\n\nUse assets/sample.txt.\n');
  const originalAlphaHash = digest(path.join(claudeAlpha, 'SKILL.md'));
  write(path.join(claudeHome, 'commands', 'old-command.md'), '---\ndescription: Legacy Claude command\n---\n\nRun the legacy workflow.\n');

  const codexAlpha = path.join(home, '.agents', 'skills', 'alpha');
  skill(codexAlpha, 'alpha', 'Codex alpha instructions.');
  write(path.join(codexAlpha, 'agents', 'openai.yaml'), 'policy:\n  allow_implicit_invocation: false\n');
  write(path.join(codexAlpha, 'scripts', 'run.sh'), '#!/bin/sh\nexit 0\n');
  fs.chmodSync(path.join(codexAlpha, 'scripts', 'run.sh'), 0o755);
  skill(path.join(home, '.agents', 'skills', 'large-one'), 'large-one', `ONE_MARKER\n${'a'.repeat(50000)}`);
  skill(path.join(home, '.agents', 'skills', 'large-two'), 'large-two', `TWO_MARKER\n${'b'.repeat(50000)}`);
  skill(path.join(home, '.agents', 'skills', 'large-three'), 'large-three', `THREE_MARKER\n${'c'.repeat(50000)}`);
  skill(path.join(home, '.agents', 'skills', 'large-unicode'), 'large-unicode', `UNICODE_MARKER\n${'界'.repeat(50000)}`);
  skill(path.join(home, '.agents', 'skills', 'disabled'), 'disabled');
  write(path.join(codexHome, 'config.toml'), `[[skills.config]]\npath = ${JSON.stringify(path.join(home, '.agents', 'skills', 'disabled'))}\nenabled = false\n`);
  skill(path.join(codexHome, 'skills', 'legacy-codex'), 'legacy-codex');
  skill(path.join(repo, '.agents', 'skills', 'root-skill'), 'root-skill');
  skill(path.join(project, '.agents', 'skills', 'nested-skill'), 'nested-skill');
  skill(path.join(repo, '.claude', 'skills', 'alpha'), 'alpha');
  skill(path.join(temporary, '.agents', 'skills', 'outside-repo'), 'outside-repo');

  const claudePlugin = path.join(claudeHome, 'plugins', 'cache', 'market', 'claude-plugin', '1.0.0');
  write(path.join(claudePlugin, '.claude-plugin', 'plugin.json'), '{"name":"claude-plugin"}\n');
  skill(path.join(claudePlugin, 'skills', 'plugin-skill'), 'plugin-skill');
  write(path.join(claudeHome, 'plugins', 'installed_plugins.json'), JSON.stringify({
    version: 2,
    plugins: { 'claude-plugin@market': [{ scope: 'user', installPath: claudePlugin, version: '1.0.0' }] },
  }));
  write(path.join(claudeHome, 'settings.json'), '{"enabledPlugins":{"claude-plugin@market":true}}\n');

  const codexPlugin = path.join(codexHome, 'plugins', 'cache', 'market', 'codex-plugin', '2.0.0');
  write(path.join(codexPlugin, '.codex-plugin', 'plugin.json'), '{"name":"codex-plugin","skills":["workflows"]}\n');
  skill(path.join(codexPlugin, 'workflows', 'plugin-task'), 'plugin-task');
  const pluginInventory = path.join(temporary, 'plugins.json');
  write(pluginInventory, JSON.stringify({ installed: [{
    pluginId: 'codex-plugin@market', name: 'codex-plugin', marketplaceName: 'market',
    version: '2.0.0', installed: true, enabled: true,
  }] }));

  const environment = {
    HOME: home,
    USERPROFILE: home,
    CLAUDEX_CONFIG_DIR: config,
    CLAUDEX_CLAUDE_CONFIG_DIR: claudeHome,
    CODEX_HOME: codexHome,
    CLAUDEX_TEST_CODEX_PLUGIN_LIST_FILE: pluginInventory,
    CLAUDEX_SKILL_BRIDGE_NO_LINKS: '1',
    CLAUDEX_CODEX_ADMIN_SKILLS_DIR: path.join(temporary, 'missing-admin'),
  };

  const first = invoke('sync', environment, project);
  assert.strictEqual(first.enabled, true);
  assert.strictEqual(first.addDirs.length, 1);
  assert(!first.pluginDirs.includes(claudePlugin), 'source plugins must never be activated wholesale');
  assert(first.pluginDirs.some((directory) => {
    try { return JSON.parse(fs.readFileSync(path.join(directory, '.claude-plugin', 'plugin.json'), 'utf8')).name === 'claude-plugin'; }
    catch { return false; }
  }), 'enabled Claude plugin skills should be exposed through an isolated compatibility plugin');
  const aliases = new Set(first.skills.map((entry) => entry.alias));
  for (const expected of ['claude-alpha', 'codex-alpha', 'old-command', 'root-skill', 'nested-skill', 'legacy-codex', 'claude-plugin:plugin-skill', 'codex-plugin:plugin-task']) {
    assert(aliases.has(expected), `missing bridged alias ${expected}`);
  }
  assert(!aliases.has('alpha'), 'an imported personal skill must not claim a native project skill short alias through --add-dir');
  assert(aliases.has('claude-alpha'), 'a personal/project collision must keep a deterministic imported alias');
  assert(!aliases.has('disabled'), 'disabled Codex skill must stay disabled');
  assert(!aliases.has('outside-repo'), 'project discovery must stop at repository root');

  const overlaySkills = path.join(first.overlay, '.claude', 'skills');
  const alphaMarkdown = fs.readFileSync(path.join(overlaySkills, 'claude-alpha', 'SKILL.md'), 'utf8');
  assert(alphaMarkdown.includes('model: gpt-5.6-terra'), 'Claude Sonnet skill should map to Terra');
  assert(alphaMarkdown.includes('name: claude-alpha'), 'qualified aliases must have matching frontmatter identity');
  const codexAlphaMarkdown = fs.readFileSync(path.join(overlaySkills, 'codex-alpha', 'SKILL.md'), 'utf8');
  assert(codexAlphaMarkdown.includes('disable-model-invocation: true'), 'Codex manual-only policy should translate');
  assert(fs.existsSync(path.join(overlaySkills, 'codex-alpha', 'scripts', 'run.sh')), 'support files should remain available');
  if (process.platform !== 'win32') {
    assert.strictEqual(fs.statSync(path.join(overlaySkills, 'codex-alpha', 'scripts', 'run.sh')).mode & 0o111, 0o111, 'script executable mode should survive copy fallback');
  }
  assert.strictEqual(digest(path.join(claudeAlpha, 'SKILL.md')), originalAlphaHash, 'source skill must never be rewritten');
  assert(first.modelMappings.some((entry) => entry.from === 'claude-sonnet-9-9' && entry.to === 'gpt-5.6-terra'));

  const referencePlugin = first.pluginDirs.find((directory) => {
    try { return JSON.parse(fs.readFileSync(path.join(directory, '.claude-plugin', 'plugin.json'), 'utf8')).name === 'claudex-codex-skill-references'; }
    catch { return false; }
  });
  assert(referencePlugin, 'Codex $skill reference compatibility plugin should be generated');
  const hook = childProcess.spawnSync(process.execPath, [path.join(referencePlugin, 'scripts', 'prompt-hook.cjs')], {
    encoding: 'utf8', input: JSON.stringify({ prompt: 'Please use $codex-alpha now.' }),
  });
  assert.strictEqual(hook.status, 0, hook.stderr);
  const hookOutput = JSON.parse(hook.stdout);
  assert(hookOutput.hookSpecificOutput.additionalContext.includes('Codex alpha instructions.'), '$skill hook should inject the explicitly referenced skill');

  const boundedHook = childProcess.spawnSync(process.execPath, [path.join(referencePlugin, 'scripts', 'prompt-hook.cjs')], {
    encoding: 'utf8', input: JSON.stringify({ prompt: 'Use $large-one, $large-two, and $large-three.' }),
  });
  assert.strictEqual(boundedHook.status, 0, boundedHook.stderr);
  const boundedContext = JSON.parse(boundedHook.stdout).hookSpecificOutput.additionalContext;
  assert(boundedContext.length <= 65536, `skill hook context exceeded its aggregate bound: ${boundedContext.length}`);
  assert(boundedContext.includes('ONE_MARKER'), 'bounded hook should preserve the first explicitly referenced skill');
  assert(boundedContext.includes('complete file'), 'truncated or omitted skills should include a complete-file recovery path');

  const unicodeHook = childProcess.spawnSync(process.execPath, [path.join(referencePlugin, 'scripts', 'prompt-hook.cjs')], {
    encoding: 'utf8', input: JSON.stringify({ prompt: 'Use "$large-unicode".' }),
  });
  assert.strictEqual(unicodeHook.status, 0, unicodeHook.stderr);
  const unicodeContext = JSON.parse(unicodeHook.stdout).hookSpecificOutput.additionalContext;
  assert(Buffer.byteLength(unicodeContext, 'utf8') <= 65536,
    `Unicode skill hook context exceeded 64 KiB: ${Buffer.byteLength(unicodeContext, 'utf8')}`);
  assert(unicodeContext.includes('UNICODE_MARKER'), 'quoted $skill reference was not recognized');

  const second = invoke('sync', environment, project);
  assert.strictEqual(second.overlay, first.overlay, 'unchanged sources should reuse immutable generation');
  fs.appendFileSync(path.join(codexAlpha, 'SKILL.md'), '\nUpdated.\n');
  const third = invoke('sync', environment, project);
  assert.notStrictEqual(third.overlay, first.overlay, 'source edits should produce a fresh generation');

  const listed = invoke('list', environment, project);
  assert(listed.includes('/codex-alpha'));
  assert(listed.includes('Claude alpha') === false, 'list output should not expose skill contents');

  const disabledBridge = invoke('sync', { ...environment, CLAUDEX_SKILL_BRIDGE: 'off' }, project);
  assert.strictEqual(disabledBridge.enabled, false);
  assert.deepStrictEqual(disabledBridge.skills, []);

  const api = require(helper);
  assert.strictEqual(api.safeName('CON'), 'skill-CON');
  assert.strictEqual(api.skillAlias('CON'), 'skill-con');
  assert.strictEqual(api.skillAlias('com1'), 'skill-com1');
  assert.strictEqual(api.safeName('d\u00e9ploiement'), 'd\u00e9ploiement');
  assert(api.ensureManualOnly('---\nname: x\n---\nbody').includes('disable-model-invocation: true'));
  assert.strictEqual(api.remapClaudeModel('---\nmodel: claude-opus-4\n---\n').mappings[0].to, 'gpt-5.6-sol');
  assert.strictEqual(api.remapClaudeModel('---\nmodel: claude-3-opus-20240229\n---\n').mappings[0].to, 'gpt-5.6-sol');
  for (const model of ['opus[1m]', 'sonnet[1m]', 'opusplan[1m]', 'claude-opus-4-8[1m]', 'best']) {
    const mapped = api.remapClaudeModel(`---\nmodel: ${model}\n---\n`);
    assert.strictEqual(mapped.mappings.length, 1, `${model} should map to a managed OpenAI model`);
    assert(!mapped.markdown.includes(`model: ${model}`), `${model} was left in the adapted skill`);
  }
  const commentedPolicy = path.join(temporary, 'commented-policy');
  write(path.join(commentedPolicy, 'agents', 'openai.yaml'), '# policy: { allow_implicit_invocation: false }\n');
  assert.strictEqual(api.codexPolicyDisablesImplicit(commentedPolicy), false, 'commented policy must stay inactive');

  process.stdout.write('skill bridge tests passed\n');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
