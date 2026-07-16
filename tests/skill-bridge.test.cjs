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

  write(path.join(codexHome, 'AGENTS.md'), 'SHADOWED_GLOBAL_INSTRUCTIONS\n');
  write(path.join(codexHome, 'AGENTS.override.md'), 'GLOBAL_OVERRIDE_INSTRUCTIONS\n');
  write(path.join(repo, 'AGENTS.md'), 'SHADOWED_ROOT_INSTRUCTIONS\n');
  write(path.join(repo, 'AGENTS.override.md'), 'ROOT_OVERRIDE_INSTRUCTIONS\n');
  write(path.join(repo, 'packages', 'AGENTS.md'), 'PACKAGE_INSTRUCTIONS\n');
  write(path.join(project, 'AGENTS.override.md'), '   \n');
  write(path.join(project, 'AGENTS.md'), 'PROJECT_FALLBACK_INSTRUCTIONS\n');
  const originalInstructionHash = digest(path.join(codexHome, 'AGENTS.override.md'));

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
  const systemCodex = path.join(codexHome, 'skills', '.system', 'system-codex');
  skill(systemCodex, 'system-codex', 'Use references/system.md and scripts/system-check.sh.');
  write(path.join(systemCodex, 'references', 'system.md'), 'SYSTEM_REFERENCE_MARKER\n');
  write(path.join(systemCodex, 'scripts', 'system-check.sh'), '#!/bin/sh\nprintf "%s\\n" SYSTEM_SCRIPT_MARKER\n');
  fs.chmodSync(path.join(systemCodex, 'scripts', 'system-check.sh'), 0o755);
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
  assert.strictEqual(first.instructions.length, 4, 'global and root-to-project Codex instructions should be snapshotted');
  const instructionSnapshot = fs.readFileSync(path.join(first.overlay, 'CLAUDE.md'), 'utf8');
  const instructionMarkers = [
    'GLOBAL_OVERRIDE_INSTRUCTIONS', 'ROOT_OVERRIDE_INSTRUCTIONS',
    'PACKAGE_INSTRUCTIONS', 'PROJECT_FALLBACK_INSTRUCTIONS',
  ];
  let previousMarker = -1;
  for (const marker of instructionMarkers) {
    const markerIndex = instructionSnapshot.indexOf(marker);
    assert(markerIndex > previousMarker, `Codex instruction precedence order is wrong for ${marker}`);
    previousMarker = markerIndex;
  }
  assert(!instructionSnapshot.includes('SHADOWED_GLOBAL_INSTRUCTIONS'), 'global AGENTS.override.md must replace AGENTS.md');
  assert(!instructionSnapshot.includes('SHADOWED_ROOT_INSTRUCTIONS'), 'project AGENTS.override.md must replace AGENTS.md');
  assert.strictEqual(digest(path.join(codexHome, 'AGENTS.override.md')), originalInstructionHash,
    'source instructions must never be rewritten');
  assert(!first.pluginDirs.includes(claudePlugin), 'source plugins must never be activated wholesale');
  assert(first.pluginDirs.some((directory) => {
    try { return JSON.parse(fs.readFileSync(path.join(directory, '.claude-plugin', 'plugin.json'), 'utf8')).name === 'claude-plugin'; }
    catch { return false; }
  }), 'enabled Claude plugin skills should be exposed through an isolated compatibility plugin');
  const aliases = new Set(first.skills.map((entry) => entry.alias));
  for (const expected of ['claude-alpha', 'codex-alpha', 'old-command', 'root-skill', 'nested-skill', 'legacy-codex', 'system-codex', 'claude-plugin:plugin-skill', 'codex-plugin:plugin-task']) {
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
  assert.strictEqual(
    fs.readFileSync(path.join(overlaySkills, 'system-codex', 'references', 'system.md'), 'utf8'),
    'SYSTEM_REFERENCE_MARKER\n',
    'Codex system-skill references should remain available',
  );
  assert(fs.existsSync(path.join(overlaySkills, 'system-codex', 'scripts', 'system-check.sh')),
    'Codex system-skill scripts should remain available');
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
    encoding: 'utf8', input: JSON.stringify({ prompt: 'Please use $codex-alpha and $claude-alpha now.' }),
  });
  assert.strictEqual(hook.status, 0, hook.stderr);
  const hookOutput = JSON.parse(hook.stdout);
  assert(hookOutput.hookSpecificOutput.additionalContext.includes('Codex alpha instructions.'), '$skill hook should inject the explicitly referenced skill');
  assert(hookOutput.hookSpecificOutput.additionalContext.includes('Use assets/sample.txt.'),
    '$skill hook should inject an explicitly referenced installed Claude skill');
  assert(hookOutput.hookSpecificOutput.additionalContext.includes('installed Codex skill $codex-alpha'),
    '$skill hook should identify a Codex source accurately');
  assert(hookOutput.hookSpecificOutput.additionalContext.includes('installed Claude Code skill $claude-alpha'),
    '$skill hook should identify a Claude source accurately');

  const boundedHook = childProcess.spawnSync(process.execPath, [path.join(referencePlugin, 'scripts', 'prompt-hook.cjs')], {
    encoding: 'utf8', input: JSON.stringify({ prompt: 'Use $large-one, $large-two, and $large-three.' }),
  });
  assert.strictEqual(boundedHook.status, 0, boundedHook.stderr);
  const boundedContext = JSON.parse(boundedHook.stdout).hookSpecificOutput.additionalContext;
  assert(Buffer.byteLength(boundedContext, 'utf8') <= 10000,
    `skill hook context exceeded Claude Code's direct hook-context bound: ${Buffer.byteLength(boundedContext, 'utf8')}`);
  assert(boundedContext.includes('ONE_MARKER'), 'bounded hook should preserve the first explicitly referenced skill');
  assert(boundedContext.includes('complete file'), 'truncated or omitted skills should include a complete-file recovery path');

  const unicodeHook = childProcess.spawnSync(process.execPath, [path.join(referencePlugin, 'scripts', 'prompt-hook.cjs')], {
    encoding: 'utf8', input: JSON.stringify({ prompt: 'Use "$large-unicode".' }),
  });
  assert.strictEqual(unicodeHook.status, 0, unicodeHook.stderr);
  const unicodeContext = JSON.parse(unicodeHook.stdout).hookSpecificOutput.additionalContext;
  assert(Buffer.byteLength(unicodeContext, 'utf8') <= 10000,
    `Unicode skill hook context exceeded Claude Code's direct hook-context bound: ${Buffer.byteLength(unicodeContext, 'utf8')}`);
  assert(unicodeContext.includes('UNICODE_MARKER'), 'quoted $skill reference was not recognized');

  const second = invoke('sync', environment, project);
  assert.strictEqual(second.overlay, first.overlay, 'unchanged sources should reuse immutable generation');
  fs.appendFileSync(path.join(codexAlpha, 'SKILL.md'), '\nUpdated.\n');
  const third = invoke('sync', environment, project);
  assert.notStrictEqual(third.overlay, first.overlay, 'source edits should produce a fresh generation');
  fs.appendFileSync(path.join(project, 'AGENTS.md'), '\nUPDATED_PROJECT_INSTRUCTIONS\n');
  const fourth = invoke('sync', environment, project);
  assert.notStrictEqual(fourth.overlay, third.overlay, 'Codex instruction edits should produce a fresh immutable generation');
  assert(fs.readFileSync(path.join(fourth.overlay, 'CLAUDE.md'), 'utf8').includes('UPDATED_PROJECT_INSTRUCTIONS'));

  const listed = invoke('list', environment, project);
  assert(listed.includes('/codex-alpha'));
  assert(listed.includes('Claude alpha') === false, 'list output should not expose skill contents');

  const disabledBridge = invoke('sync', { ...environment, CLAUDEX_SKILL_BRIDGE: 'off' }, project);
  assert.strictEqual(disabledBridge.enabled, false);
  assert.deepStrictEqual(disabledBridge.skills, []);
  assert.deepStrictEqual(disabledBridge.instructions, []);

  const disabledInstructions = invoke('sync', { ...environment, CLAUDEX_INSTRUCTION_BRIDGE: 'off' }, project);
  assert.deepStrictEqual(disabledInstructions.instructions, []);
  assert(!fs.existsSync(path.join(disabledInstructions.overlay, 'CLAUDE.md')),
    'instruction-only opt-out must not publish a CLAUDE.md compatibility file');

  const boundedRepo = path.join(temporary, 'bounded-instruction-repo');
  fs.mkdirSync(path.join(boundedRepo, '.git'), { recursive: true });
  write(path.join(boundedRepo, 'AGENTS.md'), `UNICODE_INSTRUCTION_MARKER\n${'界'.repeat(20000)}\n`);
  const bounded = invoke('sync', environment, boundedRepo);
  const boundedFile = path.join(bounded.overlay, 'CLAUDE.md');
  const boundedBytes = fs.readFileSync(boundedFile);
  const boundedText = boundedBytes.toString('utf8');
  assert(boundedBytes.length <= 32 * 1024, `Codex instruction snapshot exceeded 32 KiB: ${boundedBytes.length}`);
  assert(boundedText.includes('UNICODE_INSTRUCTION_MARKER'));
  assert(!boundedText.includes('\uFFFD'), 'UTF-8 instruction truncation split a multibyte character');
  assert(bounded.instructions.some((entry) => entry.truncated), 'truncated instruction source was not diagnosed');
  assert(bounded.warnings.some((warning) => warning.includes('instructions exceeded')),
    'bounded instruction truncation warning is missing');

  const precedenceCodexHome = path.join(temporary, 'precedence-codex-home');
  const precedenceRepo = path.join(temporary, 'precedence-instruction-repo');
  const precedenceChild = path.join(precedenceRepo, 'nested');
  fs.mkdirSync(path.join(precedenceRepo, '.git'), { recursive: true });
  fs.mkdirSync(precedenceChild, { recursive: true });
  write(path.join(precedenceCodexHome, 'AGENTS.md'), `LOW_PRECEDENCE_GLOBAL\n${'g'.repeat(40000)}\n`);
  write(path.join(precedenceRepo, 'AGENTS.md'), 'ROOT_PRECEDENCE_INSTRUCTIONS\n');
  write(path.join(precedenceChild, 'AGENTS.md'), 'HIGHEST_PRECEDENCE_CWD_INSTRUCTIONS\n');
  const precedence = invoke('sync', { ...environment, CODEX_HOME: precedenceCodexHome }, precedenceChild);
  const precedenceText = fs.readFileSync(path.join(precedence.overlay, 'CLAUDE.md'), 'utf8');
  assert(precedenceText.includes('LOW_PRECEDENCE_GLOBAL'));
  assert(!precedenceText.includes('HIGHEST_PRECEDENCE_CWD_INSTRUCTIONS'),
    'Codex forward budgeting must stop after the earlier global layer consumes the cap');
  write(path.join(precedenceCodexHome, 'config.toml'), [
    '"project_doc_max_bytes" = 65536',
    '"project_doc_fallback_filenames" = ["TEAM_GUIDE.md"]',
    '',
  ].join('\n'));
  const expandedPrecedence = invoke('sync', { ...environment, CODEX_HOME: precedenceCodexHome }, precedenceChild);
  const expandedText = fs.readFileSync(path.join(expandedPrecedence.overlay, 'CLAUDE.md'), 'utf8');
  assert(expandedText.endsWith('HIGHEST_PRECEDENCE_CWD_INSTRUCTIONS'),
    'effective project_doc_max_bytes must preserve forward global-to-CWD order when the budget fits');

  const fallbackRepo = path.join(temporary, 'fallback-instruction-repo');
  fs.mkdirSync(path.join(fallbackRepo, '.git'), { recursive: true });
  write(path.join(fallbackRepo, '.codex', 'config.toml'), 'project_doc_fallback_filenames = ["TEAM_GUIDE.md"]\n');
  write(path.join(fallbackRepo, 'TEAM_GUIDE.md'), 'FALLBACK_INSTRUCTION_MARKER\n');
  const fallbackInstructions = invoke('sync', environment, fallbackRepo);
  assert(fs.readFileSync(path.join(fallbackInstructions.overlay, 'CLAUDE.md'), 'utf8').includes('FALLBACK_INSTRUCTION_MARKER'),
    'configured Codex project instruction fallback was not bridged');

  fs.unlinkSync(boundedFile);
  const repairedInstructions = invoke('sync', environment, boundedRepo);
  assert.strictEqual(repairedInstructions.overlay, bounded.overlay,
    'a missing CLAUDE.md should rebuild the content-addressed generation');
  assert(fs.existsSync(boundedFile), 'cached manifest accepted a missing CLAUDE.md');

  const symlinkRepo = path.join(temporary, 'instruction-symlink-repo');
  const outsideInstructions = path.join(temporary, 'outside-AGENTS.md');
  fs.mkdirSync(path.join(symlinkRepo, '.git'), { recursive: true });
  write(path.join(symlinkRepo, 'AGENTS.md'), 'SAFE_SYMLINK_FALLBACK\n');
  write(outsideInstructions, 'ESCAPED_INSTRUCTIONS\n');
  let instructionSymlink = false;
  try {
    fs.symlinkSync(outsideInstructions, path.join(symlinkRepo, 'AGENTS.override.md'), 'file');
    instructionSymlink = true;
  } catch (error) {
    if (!['EPERM', 'EACCES', 'ENOTSUP'].includes(error.code)) throw error;
  }
  if (instructionSymlink) {
    const safeInstructions = invoke('sync', environment, symlinkRepo);
    const safeText = fs.readFileSync(path.join(safeInstructions.overlay, 'CLAUDE.md'), 'utf8');
    assert(safeText.includes('SAFE_SYMLINK_FALLBACK'));
    assert(!safeText.includes('ESCAPED_INSTRUCTIONS'));
    assert(safeInstructions.warnings.some((warning) => warning.includes('instruction symlink outside')),
      'escaping Codex instruction symlink was not diagnosed');
  }

  const api = require(helper);
  assert.strictEqual(api.safeName('CON'), 'skill-CON');
  assert.strictEqual(api.skillAlias('CON'), 'skill-con');
  assert.strictEqual(api.skillAlias('com1'), 'skill-com1');
  assert.strictEqual(api.safeName('d\u00e9ploiement'), 'd\u00e9ploiement');
  assert(api.ensureManualOnly('---\nname: x\n---\nbody').includes('disable-model-invocation: true'));
  const quotedIdentity = api.codexSkillIdentity('---\n"name": "quoted-name"\n\'description\': "quoted description"\n---\n');
  assert.deepStrictEqual(quotedIdentity, { valid: true, name: 'quoted-name', description: 'quoted description' });
  const quotedManual = api.ensureManualOnly('---\n"disable-model-invocation": false\n---\nbody');
  assert.strictEqual((quotedManual.match(/disable-model-invocation/g) || []).length, 1,
    'quoted YAML keys must be replaced rather than duplicated');
  assert.strictEqual(api.remapClaudeModel('---\nmodel: claude-opus-4\n---\n').mappings[0].to, 'gpt-5.6-sol');
  assert.strictEqual(api.remapClaudeModel('---\nmodel: claude-3-opus-20240229\n---\n').mappings[0].to, 'gpt-5.6-sol');
  const nestedModelMetadata = api.remapClaudeModel([
    '---',
    'name: nested-model-metadata',
    'description: Keep nested metadata exact.',
    'metadata:',
    '  model: opus',
    'hooks:',
    '  worker:',
    '    model: sonnet',
    '---',
    '',
  ].join('\n'));
  assert.strictEqual(nestedModelMetadata.mappings.length, 0,
    'nested frontmatter model keys must not be treated as Claude skill model pins');
  assert(nestedModelMetadata.markdown.includes('  model: opus'));
  assert(nestedModelMetadata.markdown.includes('    model: sonnet'));
  const mixedModelMetadata = api.remapClaudeModel([
    '---',
    'model: haiku',
    'metadata:',
    '  model: opus',
    '---',
    '',
  ].join('\n'));
  assert(mixedModelMetadata.markdown.includes('model: gpt-5.6-luna'));
  assert(mixedModelMetadata.markdown.includes('  model: opus'),
    'top-level model remapping must leave nested metadata unchanged');
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
