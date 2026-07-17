'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const childProcess = require('child_process');

const root = path.resolve(__dirname, '..');
const helper = path.join(root, 'skill-bridge.cjs');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'claudex-skill-contract-'));
const failures = [];

function write(file, contents) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, contents);
}

function writeSkill(directory, name, body = 'Follow this skill.', newline = '\n') {
  const lines = [
    '---',
    `name: ${name}`,
    `description: ${name} contract fixture`,
    '---',
    '',
    body,
    '',
  ];
  write(path.join(directory, 'SKILL.md'), lines.join(newline));
}

function invoke(environment, project) {
  const result = childProcess.spawnSync(process.execPath, [helper, 'sync', '--project', project], {
    encoding: 'utf8',
    env: { ...process.env, ...environment },
    maxBuffer: 16 * 1024 * 1024,
  });
  if (result.status !== 0) {
    throw new Error(result.stderr || result.stdout || `skill bridge exited ${result.status}`);
  }
  return JSON.parse(result.stdout);
}

function check(name, callback) {
  try {
    callback();
    process.stdout.write(`ok - ${name}\n`);
  } catch (error) {
    failures.push({ name, error });
    process.stderr.write(`not ok - ${name}: ${error.message}\n`);
  }
}

function expect(condition, message) {
  if (!condition) throw new Error(message);
}

function aliases(result) {
  return new Set(result.skills.map((entry) => entry.alias));
}

function overlaySkillFile(result, alias) {
  return path.join(result.overlay, '.claude', 'skills', alias, 'SKILL.md');
}

function pluginName(pluginDirectory) {
  for (const relative of ['.claude-plugin/plugin.json', '.codex-plugin/plugin.json']) {
    try {
      return JSON.parse(fs.readFileSync(path.join(pluginDirectory, relative), 'utf8')).name || '';
    } catch { }
  }
  return '';
}

function pluginSkillExists(result, namespace, skillName) {
  if (aliases(result).has(`${namespace}:${skillName}`)) return true;
  return result.pluginDirs.some((pluginDirectory) => {
    if (pluginName(pluginDirectory) !== namespace) return false;
    return fs.existsSync(path.join(pluginDirectory, 'skills', skillName, 'SKILL.md'));
  });
}

function environmentFor(home, config, codexHome, pluginInventory, extra = {}) {
  return {
    HOME: home,
    USERPROFILE: home,
    CLAUDEX_CONFIG_DIR: config,
    CLAUDEX_CLAUDE_CONFIG_DIR: path.join(home, '.claude'),
    CODEX_HOME: codexHome,
    CLAUDEX_TEST_CODEX_PLUGIN_LIST_FILE: pluginInventory,
    CLAUDEX_SKILL_BRIDGE_NO_LINKS: '1',
    CLAUDEX_CODEX_ADMIN_SKILLS_DIR: path.join(home, 'missing-admin-skills'),
    ...extra,
  };
}

try {
  const home = path.join(temporary, 'primary home');
  const config = path.join(home, '.config', 'claudex');
  const codexHome = path.join(home, '.codex');
  const claudeHome = path.join(home, '.claude');
  const repo = path.join(temporary, 'repo');
  const project = path.join(repo, 'packages', 'web');
  fs.mkdirSync(path.join(repo, '.git'), { recursive: true });
  fs.mkdirSync(project, { recursive: true });

  // Codex identity comes from required frontmatter, not necessarily the folder.
  writeSkill(path.join(home, '.agents', 'skills', 'folder-identity'), 'frontmatter-identity');
  writeSkill(path.join(home, '.agents', 'skills', 'reserved-folder'), 'con');
  writeSkill(path.join(codexHome, 'skills', '.system', 'bundled-tool'), 'bundled-tool',
    'Run the bundled Codex workflow.');
  writeSkill(path.join(claudeHome, 'skills', 'override-disabled'), 'override-disabled');
  write(path.join(claudeHome, 'skills', 'override-name-only', 'SKILL.md'), [
    '---',
    'name: override-name-only',
    'description: |',
    '  PRIVATE_DESCRIPTION_LINE',
    '  PRIVATE_DESCRIPTION_CONTINUATION',
    'when_to_use: PRIVATE_TRIGGER_TEXT',
    '---',
    '',
    'NAME_ONLY_BODY',
    '',
  ].join('\n'));
  writeSkill(path.join(claudeHome, 'skills', 'override-user-only'), 'override-user-only', 'USER_ONLY_BODY');
  writeSkill(path.join(claudeHome, 'skills', 'local-precedence'), 'local-precedence', 'LOCAL_PRECEDENCE_BODY');

  const skillsDirectoryPlugin = path.join(claudeHome, 'skills', 'skills-directory-plugin');
  write(path.join(skillsDirectoryPlugin, '.claude-plugin', 'plugin.json'), JSON.stringify({
    name: 'skills-directory', defaultEnabled: true,
    commands: ['./custom'],
  }));
  writeSkill(skillsDirectoryPlugin, 'root-tool', 'ROOT_PLUGIN_BODY');
  writeSkill(path.join(skillsDirectoryPlugin, 'skills', 'nested'), 'nested', 'NESTED_PLUGIN_BODY');
  write(path.join(skillsDirectoryPlugin, 'custom', 'deploy.md'), '---\ndescription: Deploy directly\n---\n\nDIRECT_COMMAND_BODY\n');
  writeSkill(path.join(skillsDirectoryPlugin, 'custom', 'team', 'release'), 'release-command', 'NESTED_COMMAND_BODY');
  write(path.join(skillsDirectoryPlugin, 'Hooks', 'dangerous.js'), 'throw new Error("must not activate");\n');
  const rootFallbackPlugin = path.join(claudeHome, 'skills', 'root-fallback-plugin');
  write(path.join(rootFallbackPlugin, '.claude-plugin', 'plugin.json'), JSON.stringify({ name: 'root-fallback' }));
  writeSkill(rootFallbackPlugin, 'root-fallback-tool', 'ROOT_FALLBACK_BODY');

  // CRLF is common in Windows-authored skills and must remain valid when adapted.
  const crlfRoot = path.join(home, '.agents', 'skills', 'crlf-manual');
  writeSkill(crlfRoot, 'crlf-manual', 'Run the CRLF workflow.', '\r\n');
  write(path.join(crlfRoot, 'agents', 'openai.yaml'), 'policy:\r\n  allow_implicit_invocation: false\r\n');

  // Valid compact YAML must carry the same manual-only policy.
  const inlinePolicyRoot = path.join(home, '.agents', 'skills', 'inline-policy');
  writeSkill(inlinePolicyRoot, 'inline-policy');
  write(path.join(inlinePolicyRoot, 'agents', 'openai.yaml'), '"policy": { "allow_implicit_invocation": false }\n');

  // Adapted support files participate in generation freshness when links are unavailable.
  const supportRoot = path.join(home, '.agents', 'skills', 'support-refresh');
  writeSkill(supportRoot, 'support-refresh', 'Read support.txt.');
  write(path.join(supportRoot, 'agents', 'openai.yaml'), 'policy:\n  allow_implicit_invocation: false\n');
  write(path.join(supportRoot, 'support.txt'), 'first support revision\n');

  // A raw semver build suffix is part of the documented cache directory identity.
  const namespacedPlugin = path.join(
    codexHome, 'plugins', 'cache', 'market', 'github', '1.2.3+build.7',
  );
  write(path.join(namespacedPlugin, '.codex-plugin', 'plugin.json'), JSON.stringify({
    name: 'github',
    version: '1.2.3+build.7',
    skills: './skills/',
  }));
  writeSkill(path.join(namespacedPlugin, 'skills', 'repair-folder'), 'gh-repair');

  // Claude-format plugins installed through Codex still obey Codex skill disables.
  const claudeFormatPlugin = path.join(
    codexHome, 'plugins', 'cache', 'market', 'claude-origin', '2.0.0',
  );
  write(path.join(claudeFormatPlugin, '.claude-plugin', 'plugin.json'), JSON.stringify({
    name: 'claude-origin', version: '2.0.0', skills: './custom-skills/',
  }));
  writeSkill(path.join(claudeFormatPlugin, 'skills', 'visible'), 'visible');
  writeSkill(path.join(claudeFormatPlugin, 'custom-skills', 'custom-visible'), 'custom-visible');
  const disabledPluginSkill = path.join(claudeFormatPlugin, 'skills', 'hidden');
  writeSkill(disabledPluginSkill, 'hidden');

  // If both manifests exist, the Codex manifest and its configured skills path win.
  const hybridPlugin = path.join(
    codexHome, 'plugins', 'cache', 'market', 'hybrid', '3.0.0',
  );
  write(path.join(hybridPlugin, '.codex-plugin', 'plugin.json'), JSON.stringify({
    name: 'hybrid', version: '3.0.0', skills: './codex-workflows/',
  }));
  write(path.join(hybridPlugin, '.claude-plugin', 'plugin.json'), JSON.stringify({
    name: 'hybrid', version: '3.0.0',
  }));
  writeSkill(path.join(hybridPlugin, 'codex-workflows', 'primary-folder'), 'codex-primary');
  writeSkill(path.join(hybridPlugin, 'skills', 'legacy-only'), 'legacy-only');

  // A hybrid package installed through Claude must prefer its Claude manifest.
  const claudeHybridPlugin = path.join(claudeHome, 'plugins', 'cache', 'market', 'claude-hybrid', '4.0.0');
  write(path.join(claudeHybridPlugin, '.claude-plugin', 'plugin.json'), JSON.stringify({
    name: 'claude-hybrid', version: '4.0.0', skills: './claude-workflows/',
  }));
  write(path.join(claudeHybridPlugin, '.codex-plugin', 'plugin.json'), JSON.stringify({
    name: 'claude-hybrid', version: '4.0.0', skills: './codex-workflows/',
  }));
  writeSkill(path.join(claudeHybridPlugin, 'claude-workflows', 'claude-choice'), 'claude-choice');
  writeSkill(path.join(claudeHybridPlugin, 'codex-workflows', 'codex-choice'), 'codex-choice');
  const disabledByDefaultPlugin = path.join(claudeHome, 'plugins', 'cache', 'market', 'disabled-default', '1.0.0');
  write(path.join(disabledByDefaultPlugin, '.claude-plugin', 'plugin.json'), JSON.stringify({
    name: 'disabled-default', defaultEnabled: false,
  }));
  writeSkill(path.join(disabledByDefaultPlugin, 'skills', 'hidden-default'), 'hidden-default');
  write(path.join(claudeHome, 'plugins', 'installed_plugins.json'), JSON.stringify({
    plugins: {
      'claude-hybrid@market': [{ scope: 'user', installPath: claudeHybridPlugin }],
      'disabled-default@market': [{ scope: 'user', installPath: disabledByDefaultPlugin }],
    },
  }));
  write(path.join(claudeHome, 'settings.json'), JSON.stringify({
    enabledPlugins: { 'claude-hybrid@market': true },
    skillOverrides: {
      'override-disabled': 'off',
      'override-name-only': 'name-only',
      'override-user-only': 'user-invocable-only',
    },
  }));
  write(path.join(project, '.claude', 'settings.local.json'), JSON.stringify({
    skillOverrides: { 'local-precedence': 'off' },
  }));
  write(path.join(repo, '.claude', 'settings.local.json'), JSON.stringify({
    skillOverrides: { 'local-precedence': 'on' },
  }));

  const projectDisabled = path.join(repo, '.agents', 'skills', 'project-disabled');
  writeSkill(projectDisabled, 'project-disabled');
  write(path.join(repo, '.codex', 'config.toml'), [
    '[["skills"."config"]]',
    '"path" = "../.agents/skills/project-disabled"',
    '"enabled" = false',
    '',
  ].join('\n'));

  write(path.join(codexHome, 'config.toml'), [
    '[[skills.config]]',
    `path = ${JSON.stringify(disabledPluginSkill)}`,
    'enabled = false',
    '',
  ].join('\n'));

  const pluginInventory = path.join(temporary, 'primary-plugins.json');
  write(pluginInventory, JSON.stringify({
    installed: [
      {
        pluginId: 'github@market', name: 'github', marketplaceName: 'market',
        version: '1.2.3+build.7', installed: true, enabled: true,
      },
      {
        pluginId: 'claude-origin@market', name: 'claude-origin', marketplaceName: 'market',
        version: '2.0.0', installed: true, enabled: true,
      },
      {
        pluginId: 'hybrid@market', name: 'hybrid', marketplaceName: 'market',
        version: '3.0.0', installed: true, enabled: true,
      },
    ],
  }));

  const environment = environmentFor(home, config, codexHome, pluginInventory);
  const first = invoke(environment, project);

  check('Codex frontmatter name is the explicit skill identity', () => {
    const discovered = aliases(first);
    expect(discovered.has('frontmatter-identity'),
      `expected frontmatter alias, got: ${[...discovered].join(', ')}`);
  });

  check('Windows reserved Codex names receive a portable alias', () => {
    expect(aliases(first).has('skill-con'), 'reserved identity con was not mapped to skill-con');
  });

  check('Codex bundled system skills are available in Claudex', () => {
    const system = first.skills.find((entry) => entry.alias === 'bundled-tool');
    expect(system && system.kind === 'codex-system', 'CODEX_HOME/skills/.system was not discovered');
    expect(fs.readFileSync(overlaySkillFile(first, 'bundled-tool'), 'utf8').includes('bundled Codex workflow'),
      'bundled Codex skill instructions were not snapshotted');
  });

  check('Claude personal skillOverrides stay disabled in Claudex', () => {
    expect(!aliases(first).has('override-disabled'), 'disabled Claude personal skill was imported');
    expect(aliases(first).has('local-precedence'), 'repository-root settings.local.json must override a legacy nested local file');
  });

  check('Claude visibility overrides preserve name-only and user-only states', () => {
    const nameOnly = fs.readFileSync(overlaySkillFile(first, 'override-name-only'), 'utf8');
    const userOnly = fs.readFileSync(overlaySkillFile(first, 'override-user-only'), 'utf8');
    expect(/^description:\s*""\s*$/m.test(nameOnly), 'name-only description remained model-visible');
    expect(/^when_to_use:\s*""\s*$/m.test(nameOnly), 'name-only trigger text remained model-visible');
    expect(!nameOnly.includes('PRIVATE_DESCRIPTION_') && !nameOnly.includes('PRIVATE_TRIGGER_TEXT'),
      'multiline name-only metadata was not fully removed');
    expect(!/disable-model-invocation:\s*true/.test(nameOnly), 'name-only skill was made fully manual');
    expect(/disable-model-invocation:\s*true/.test(userOnly), 'user-invocable-only skill remained model-invocable');
  });

  check('skills-directory plugins and direct command files are namespaced', () => {
    expect(!pluginSkillExists(first, 'skills-directory', 'root-tool'),
      'plugin-root SKILL.md must be ignored when the default skills directory exists');
    expect(pluginSkillExists(first, 'skills-directory', 'nested'), 'nested plugin skill was omitted');
    expect(pluginSkillExists(first, 'skills-directory', 'deploy'), 'direct-file plugin command was omitted');
    expect(pluginSkillExists(first, 'skills-directory', 'release-command'), 'nested command SKILL.md was omitted');
    expect(pluginSkillExists(first, 'root-fallback', 'root-fallback-tool'),
      'plugin-root SKILL.md fallback was omitted when no skills directory exists');
    const pluginDirectory = first.pluginDirs.find((directory) => pluginName(directory) === 'skills-directory');
    expect(pluginDirectory, 'skills-directory compatibility plugin was not generated');
    expect(!fs.existsSync(path.join(pluginDirectory, 'skills', 'nested', '.claude-plugin')),
      'source plugin manifest was copied into a generated skill');
  });

  check('default-disabled Claude plugins remain unavailable', () => {
    expect(!pluginSkillExists(first, 'disabled-default', 'hidden-default'),
      'defaultEnabled:false plugin was imported without an explicit enable');
  });

  const pluginsOff = invoke({ ...environment, CLAUDEX_SKILL_PLUGINS: 'off' }, project);
  check('global plugin opt-out includes skills-directory plugins', () => {
    expect(!pluginsOff.skills.some((entry) => /plugin/.test(entry.kind)),
      'CLAUDEX_SKILL_PLUGINS=off left imported plugin skills enabled');
    expect(!pluginSkillExists(pluginsOff, 'skills-directory', 'nested'),
      'skills-directory plugin bypassed the global plugin opt-out');
  });

  check('project Codex config disables relative skill paths', () => {
    expect(!aliases(first).has('project-disabled'), 'project .codex/config.toml disable was ignored');
  });

  check('CRLF manual-only adaptation keeps valid YAML frontmatter', () => {
    const file = overlaySkillFile(first, 'crlf-manual');
    const markdown = fs.readFileSync(file, 'utf8');
    expect(/^---\r?\n/.test(markdown), 'opening YAML delimiter was corrupted');
    const closing = markdown.search(/\r?\n---\r?\n/);
    expect(closing > 0, 'closing YAML delimiter is missing');
    expect(markdown.slice(0, closing).includes('disable-model-invocation: true'),
      'manual-only flag is missing from frontmatter');
    expect(!markdown.startsWith('---\rdisable-model-invocation'),
      'manual-only flag was inserted into the CRLF delimiter');
  });

  check('compact openai.yaml policy disables implicit invocation', () => {
    const markdown = fs.readFileSync(overlaySkillFile(first, 'inline-policy'), 'utf8');
    expect(/^[ \t]*disable-model-invocation:\s*true\s*$/m.test(markdown),
      'inline YAML policy was not translated');
  });

  check('Codex plugin skill keeps plugin namespace and frontmatter identity', () => {
    expect(pluginSkillExists(first, 'github', 'gh-repair'),
      'expected explicit github:gh-repair plugin skill');
  });

  check('cache lookup preserves semver build metadata', () => {
    const found = first.skills.some((entry) => entry.source.startsWith(namespacedPlugin))
      || first.pluginDirs.some((entry) => path.resolve(entry) === path.resolve(namespacedPlugin));
    expect(found, 'plugin cache version 1.2.3+build.7 was not discovered');
  });

  check('disabled skill is filtered from a Claude-format Codex plugin', () => {
    expect(!first.pluginDirs.some((entry) => path.resolve(entry) === path.resolve(claudeFormatPlugin)),
      'unfiltered original Claude-format plugin was forwarded');
    expect(pluginSkillExists(first, 'claude-origin', 'visible'),
      'default Claude plugin skill is missing when manifest extends skills paths');
    expect(pluginSkillExists(first, 'claude-origin', 'custom-visible'),
      'custom Claude plugin skill path is missing');
    expect(!pluginSkillExists(first, 'claude-origin', 'hidden'),
      'disabled plugin skill is still invocable');
    expect(!first.skills.some((entry) => path.resolve(entry.source) === path.resolve(disabledPluginSkill)),
      'disabled plugin skill was copied into the generic overlay');
  });

  check('hybrid plugin prefers the Codex manifest skills path', () => {
    expect(pluginSkillExists(first, 'hybrid', 'codex-primary'),
      'skill from .codex-plugin manifest path is missing');
    expect(!pluginSkillExists(first, 'hybrid', 'legacy-only'),
      'Claude fallback skill incorrectly overrode the Codex manifest');
  });

  check('Claude-installed hybrid plugin prefers the Claude manifest', () => {
    expect(pluginSkillExists(first, 'claude-hybrid', 'claude-choice'),
      'skill from .claude-plugin manifest path is missing');
    expect(!pluginSkillExists(first, 'claude-hybrid', 'codex-choice'),
      'Codex manifest incorrectly overrode the Claude installation');
  });

  check('support-file edits refresh a copy-fallback generation', () => {
    const firstRecord = first.skills.find((entry) => entry.alias === 'support-refresh');
    expect(firstRecord, 'support-refresh skill was not discovered');
    write(path.join(supportRoot, 'support.txt'), 'second support revision is longer\n');
    const second = invoke(environment, project);
    expect(second.overlay !== first.overlay, 'support-only edit reused the stale generation');
    const support = fs.readFileSync(path.join(
      second.overlay, '.claude', 'skills', 'support-refresh', 'support.txt',
    ), 'utf8');
    expect(support === 'second support revision is longer\n', 'refreshed support file is stale');
  });

  // Exercise an equivalent valid TOML representation, not only array-table syntax.
  const structuredHome = path.join(temporary, 'structured home');
  const structuredConfig = path.join(structuredHome, '.config', 'claudex');
  const structuredCodexHome = path.join(structuredHome, '.codex');
  const structuredRepo = path.join(temporary, 'structured repo');
  fs.mkdirSync(path.join(structuredRepo, '.git'), { recursive: true });
  const inlineDisabled = path.join(structuredHome, '.agents', 'skills', 'inline-disabled');
  const inlineReenabled = path.join(structuredHome, '.agents', 'skills', 'inline-reenabled');
  writeSkill(inlineDisabled, 'inline-disabled');
  writeSkill(inlineReenabled, 'inline-reenabled');
  write(path.join(structuredRepo, 'TEAM_GUIDE.md'), 'MULTILINE_FALLBACK_MARKER\n');
  write(path.join(structuredCodexHome, 'config.toml'), [
    'project_doc_fallback_filenames = [',
    '  "TEAM_GUIDE.md", # valid multiline TOML array',
    ']',
    '[[skills.config]]',
    `path = ${JSON.stringify(inlineDisabled)}`,
    'enabled = false',
    '[[skills.config]]',
    `path = ${JSON.stringify(inlineReenabled)}`,
    'enabled = false',
    '[[skills.config]]',
    `path = ${JSON.stringify(inlineReenabled)}`,
    'enabled = true',
    '',
  ].join('\n'));
  const emptyInventory = path.join(temporary, 'empty-plugins.json');
  write(emptyInventory, '{"installed":[]}\n');
  const structured = invoke(
    environmentFor(structuredHome, structuredConfig, structuredCodexHome, emptyInventory),
    structuredRepo,
  );

  const inlineHome = path.join(temporary, 'inline home');
  const inlineConfig = path.join(inlineHome, '.config', 'claudex');
  const inlineCodexHome = path.join(inlineHome, '.codex');
  const inlineRepo = path.join(temporary, 'inline repo');
  fs.mkdirSync(path.join(inlineRepo, '.git'), { recursive: true });
  const independentlyInlineDisabled = path.join(inlineHome, '.agents', 'skills', 'independently-inline-disabled');
  writeSkill(independentlyInlineDisabled, 'independently-inline-disabled');
  write(path.join(inlineCodexHome, 'config.toml'),
    `skills.config = [{ path = ${JSON.stringify(independentlyInlineDisabled)}, enabled = false }]\n`);
  const inlineOnly = invoke(
    environmentFor(inlineHome, inlineConfig, inlineCodexHome, emptyInventory),
    inlineRepo,
  );

  check('repeated TOML array tables preserve textual last-wins ordering', () => {
    expect(!aliases(structured).has('inline-disabled'),
      'valid array-table skills.config was ignored');
    expect(aliases(structured).has('inline-reenabled'),
      'textually later array-table entry did not re-enable an earlier array-table disable');
    expect(fs.readFileSync(path.join(structured.overlay, 'CLAUDE.md'), 'utf8').includes('MULTILINE_FALLBACK_MARKER'),
      'multiline project_doc_fallback_filenames was ignored');
  });

  check('standalone inline-table TOML skills.config remains supported', () => {
    expect(!aliases(inlineOnly).has('independently-inline-disabled'),
      'valid dotted-key inline-table skills.config was ignored');
  });
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}

if (failures.length > 0) {
  process.stderr.write(`\n${failures.length} Codex skill contract regression(s) failed.\n`);
  process.exitCode = 1;
} else {
  process.stdout.write('Codex skill contract regressions passed\n');
}
