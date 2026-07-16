#!/usr/bin/env node
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const childProcess = require('child_process');

const BRIDGE_SCHEMA = 3;
const BRIDGE_FORMAT = 'skills-v3-snapshot-20260716';
const MAX_FILES = 4096;
const MAX_FILE_BYTES = 16 * 1024 * 1024;
const MAX_TREE_BYTES = 64 * 1024 * 1024;
const MAX_DEPTH = 32;
const MAX_GENERATIONS_PER_PROJECT = 8;
const MAX_TOTAL_GENERATIONS = 256;
const MAX_STAGE_DIRECTORIES = 8;
const STALE_STAGE_MS = 24 * 60 * 60 * 1000;
const STALE_GC_LOCK_MS = 10 * 60 * 1000;
const FILE_FINGERPRINT_VERSION = 2;
const isWindows = process.platform === 'win32';
const home = path.resolve(isWindows
  ? (process.env.USERPROFILE || os.homedir())
  : (process.env.HOME || os.homedir()));
function expandHome(value) {
  const text = String(value || '');
  return text === '~' ? home : text.startsWith(`~${path.sep}`) || text.startsWith('~/') || text.startsWith('~\\')
    ? path.join(home, text.slice(2)) : text;
}
const configDir = path.resolve(expandHome(process.env.CLAUDEX_CONFIG_DIR || path.join(home, '.config', 'claudex')));
const claudeHome = path.resolve(expandHome(process.env.CLAUDEX_CLAUDE_CONFIG_DIR || path.join(home, '.claude')));
const codexHome = path.resolve(expandHome(process.env.CODEX_HOME || path.join(home, '.codex')));
const bridgeEnabled = (process.env.CLAUDEX_SKILL_BRIDGE || 'on') !== 'off';
const pluginEnabled = (process.env.CLAUDEX_SKILL_PLUGINS || 'on') !== 'off';
const dollarReferencesEnabled = (process.env.CLAUDEX_SKILL_DOLLAR_REFERENCES || 'on') !== 'off';

class SourceChangedError extends Error { }

function existsDirectory(candidate) {
  try { return fs.statSync(candidate).isDirectory(); } catch { return false; }
}

function existsFile(candidate) {
  try { return fs.statSync(candidate).isFile(); } catch { return false; }
}

function readJson(candidate, fallback) {
  try {
    const value = JSON.parse(fs.readFileSync(candidate, 'utf8'));
    return value === null ? fallback : value;
  } catch { return fallback; }
}

let digestCache;
const nextDigestCache = {};

function cachedFileFingerprint(file, stat) {
  if (!digestCache) digestCache = readJson(path.join(configDir, 'skill-bridge', 'digest-cache.json'), {});
  const key = canonical(file);
  const stamp = [FILE_FINGERPRINT_VERSION, stat.size, stat.mtimeMs, stat.ctimeMs, stat.ino || 0, stat.mode & 0o777].join(':');
  const cached = digestCache && digestCache[key];
  if (cached && cached.stamp === stamp && typeof cached.digest === 'string') {
    nextDigestCache[key] = cached;
    return cached;
  }
  const bytes = fs.readFileSync(file);
  if (bytes.length !== stat.size) throw new SourceChangedError(`skill changed while reading: ${file}`);
  const record = {
    stamp,
    digest: crypto.createHash('sha256').update(bytes).digest('hex'),
    sensitive: sensitiveContent(bytes),
  };
  nextDigestCache[key] = record;
  return record;
}

function saveDigestCache() {
  const directory = path.join(configDir, 'skill-bridge');
  let temporary = '';
  try {
    fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
    temporary = path.join(directory, `.digest-cache-${process.pid}-${crypto.randomBytes(4).toString('hex')}`);
    fs.writeFileSync(temporary, `${JSON.stringify(nextDigestCache)}\n`, { mode: 0o600, flag: 'wx' });
    const destination = path.join(directory, 'digest-cache.json');
    if (isWindows) fs.rmSync(destination, { force: true });
    fs.renameSync(temporary, destination);
    temporary = '';
  } catch { }
  finally { if (temporary) fs.rmSync(temporary, { force: true }); }
}

function canonical(candidate) {
  try { return fs.realpathSync.native(candidate); } catch { return path.resolve(candidate); }
}

function isWithin(candidate, parent) {
  const relative = path.relative(canonical(parent), canonical(candidate));
  return relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative));
}

function safeName(value, fallback = 'skill') {
  let name = String(value || '').normalize('NFC').trim();
  name = name.replace(/[<>:"/\\|?*\u0000-\u001f]/g, '-');
  name = name.replace(/[^\p{L}\p{N}._-]+/gu, '-').replace(/-+/g, '-');
  name = name.replace(/^[. -]+|[. -]+$/g, '').slice(0, 64) || fallback;
  if (/^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(name)) name = `skill-${name}`.slice(0, 64);
  return name;
}

function skillAlias(value, fallback = 'skill') {
  let name = String(value || '').normalize('NFKD').toLocaleLowerCase();
  name = name.replace(/[^a-z0-9]+/g, '-').replace(/-+/g, '-').replace(/^-|-$/g, '').slice(0, 64);
  name = name || safeName(fallback).toLocaleLowerCase().replace(/[^a-z0-9-]/g, '-') || 'skill';
  if (/^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:-|$)/i.test(name)) name = `skill-${name}`.slice(0, 64);
  return name;
}

function safeCacheSegment(value) {
  if (typeof value !== 'string' || value.length === 0 || value === '.' || value === '..') return null;
  if (value.includes('/') || value.includes('\\') || value.includes('\0')) return null;
  return value;
}

function findRepoRoot(start) {
  let cursor = path.resolve(start);
  while (true) {
    if (fs.existsSync(path.join(cursor, '.git'))) return cursor;
    const parent = path.dirname(cursor);
    if (parent === cursor) return path.resolve(start);
    cursor = parent;
  }
}

function ancestry(start, stop) {
  const result = [];
  let cursor = path.resolve(start);
  const boundary = path.resolve(stop);
  while (true) {
    result.push(cursor);
    if (cursor === boundary) return result;
    const parent = path.dirname(cursor);
    if (parent === cursor) return result;
    cursor = parent;
  }
}

function decodeQuotedScalar(raw) {
  const value = String(raw || '').trim();
  if (value.startsWith('"') && value.endsWith('"')) {
    try { return JSON.parse(value); } catch { return value.slice(1, -1); }
  }
  if (value.startsWith("'") && value.endsWith("'")) return value.slice(1, -1).replace(/''/g, "'");
  return value.replace(/\s+#.*$/, '').trim();
}

function frontmatter(markdown) {
  const match = String(markdown).match(/^(\uFEFF?---)(\r?\n)([\s\S]*?)(\r?\n)---[ \t]*(\r?\n|$)/);
  if (!match) return null;
  return {
    open: match[1], eol: match[2], body: match[3], closePrefix: match[4], closeEol: match[5],
    full: match[0], rest: markdown.slice(match[0].length),
  };
}

function yamlTopLevelScalar(markdown, key) {
  const parsed = frontmatter(markdown);
  if (!parsed) return null;
  const escaped = key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const match = parsed.body.match(new RegExp(`^${escaped}\\s*:\\s*(.+?)\\s*$`, 'mi'));
  return match ? decodeQuotedScalar(match[1]) : null;
}

function replaceFrontmatterField(markdown, key, value) {
  const parsed = frontmatter(markdown);
  if (!parsed) return markdown;
  const escaped = key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const line = `${key}: ${value}`;
  const expression = new RegExp(`^${escaped}\\s*:\\s*(.*)$`, 'i');
  const lines = parsed.body.split(/\r?\n/);
  const index = lines.findIndex((entry) => expression.test(entry));
  if (index >= 0) {
    const scalar = (lines[index].match(expression) || [null, ''])[1].trim();
    let end = index + 1;
    if (scalar === '' || /^[>|][+-]?[0-9]*$/.test(scalar)) {
      while (end < lines.length && (lines[end].trim() === '' || /^\s+/.test(lines[end]))) end++;
    }
    lines.splice(index, end - index, line);
  } else lines.unshift(line);
  const body = lines.join(parsed.eol);
  return `${parsed.open}${parsed.eol}${body}${parsed.closePrefix}---${parsed.closeEol}${parsed.rest}`;
}

function setFrontmatterField(markdown, key, value) {
  if (!frontmatter(markdown)) return `---\n${key}: ${value}\n---\n\n${markdown}`;
  return replaceFrontmatterField(markdown, key, value);
}

function codexSkillIdentity(markdown) {
  const name = yamlTopLevelScalar(markdown, 'name');
  const description = yamlTopLevelScalar(markdown, 'description');
  if (!name || !description) return { valid: false, reason: 'Codex skills require name and description frontmatter' };
  if (name.length > 128 || /[\u0000-\u001f/\\]/.test(name)) return { valid: false, reason: `Codex skill name is invalid: ${name}` };
  return { valid: true, name, description };
}

function tomlString(raw) {
  const value = String(raw || '').trim();
  if (value.startsWith('"')) {
    const match = value.match(/^"(?:\\.|[^"\\])*"/);
    if (!match) return null;
    try { return JSON.parse(match[0]); } catch { return null; }
  }
  if (value.startsWith("'")) {
    const end = value.indexOf("'", 1);
    return end < 0 ? null : value.slice(1, end);
  }
  return null;
}

function addDisabledPath(disabled, rawPath, baseDirectory = codexHome) {
  if (!rawPath) return;
  const configured = path.isAbsolute(rawPath) ? rawPath : path.resolve(baseDirectory, rawPath);
  disabled.add(canonical(configured));
  if (/SKILL\.md$/i.test(configured)) disabled.add(canonical(path.dirname(configured)));
}

function parseDisabledCodexSkills(projectDir, repoRoot) {
  const disabled = new Set();
  const files = [path.join(codexHome, 'config.toml')];
  if (projectDir && repoRoot) {
    for (const directory of ancestry(projectDir, repoRoot).reverse()) files.push(path.join(directory, '.codex', 'config.toml'));
  }
  for (const file of files) {
    let source = '';
    try { source = fs.readFileSync(file, 'utf8'); } catch { continue; }
    const baseDirectory = path.dirname(file);

    const blocks = source.split(/^\s*\[\[\s*skills\.config\s*\]\]\s*$/m).slice(1);
    for (const block of blocks) {
      const body = block.split(/^\s*\[\[/m)[0];
      if (!/^\s*enabled\s*=\s*false\s*(?:#.*)?$/mi.test(body)) continue;
      const match = body.match(/^\s*path\s*=\s*((?:"(?:\\.|[^"\\])*")|(?:'[^']*'))/mi);
      if (match) addDisabledPath(disabled, tomlString(match[1]), baseDirectory);
    }

    const inline = source.match(/(?:^|\n)\s*skills\.config\s*=\s*\[([\s\S]*?)\]\s*(?:#.*)?(?:\n|$)/m);
    if (inline) {
      for (const table of inline[1].matchAll(/\{([\s\S]*?)\}/g)) {
        if (!/(?:^|,)\s*enabled\s*=\s*false\s*(?:,|$)/i.test(table[1])) continue;
        const match = table[1].match(/(?:^|,)\s*path\s*=\s*((?:"(?:\\.|[^"\\])*")|(?:'[^']*'))/i);
        if (match) addDisabledPath(disabled, tomlString(match[1]), baseDirectory);
      }
    }
  }
  return disabled;
}

function codexPolicyDisablesImplicit(skillRoot) {
  let source = '';
  try { source = fs.readFileSync(path.join(skillRoot, 'agents', 'openai.yaml'), 'utf8'); } catch { return false; }
  if (/^\s*policy\s*:\s*\{[^}\r\n]*\ballow_implicit_invocation\s*:\s*false\b[^}\r\n]*\}\s*(?:#.*)?$/mi.test(source)) return true;
  const lines = source.split(/\r?\n/);
  let policyIndent = -1;
  for (const line of lines) {
    if (/^\s*(?:#.*)?$/.test(line)) continue;
    const indent = (line.match(/^\s*/) || [''])[0].length;
    if (/^\s*policy\s*:\s*(?:&[A-Za-z0-9_-]+\s*)?(?:#.*)?$/.test(line)) { policyIndent = indent; continue; }
    if (policyIndent >= 0 && indent <= policyIndent) policyIndent = -1;
    if (policyIndent >= 0 && /^\s*allow_implicit_invocation\s*:\s*false\s*(?:#.*)?$/i.test(line)) return true;
  }
  return false;
}

function remapClaudeModel(markdown) {
  const parsed = frontmatter(markdown);
  if (!parsed) return { markdown, changed: false, mappings: [] };
  const mappings = [];
  const replaced = parsed.body.replace(/^(\s*model\s*:\s*)(["']?)([^\s#"']+)\2(\s*(?:#.*)?)$/gmi,
    (line, prefix, quote, model, suffix) => {
      const normalized = model.toLocaleLowerCase().replace(/\[1m\]$/, '');
      if (!/(?:opus|sonnet|haiku|fable|best)/.test(normalized)) return line;
      const family = /(?:opus|fable|best)/.test(normalized) ? 'gpt-5.6-sol' : /haiku/.test(normalized) ? 'gpt-5.6-luna' : 'gpt-5.6-terra';
      mappings.push({ from: model, to: family });
      return `${prefix}${quote}${family}${quote}${suffix}`;
    });
  const result = `${parsed.open}${parsed.eol}${replaced}${parsed.closePrefix}---${parsed.closeEol}${parsed.rest}`;
  return { markdown: result, changed: mappings.length > 0, mappings };
}

function ensureManualOnly(markdown) {
  const parsed = frontmatter(markdown);
  if (!parsed) return `---\ndisable-model-invocation: true\n---\n\n${markdown}`;
  return replaceFrontmatterField(markdown, 'disable-model-invocation', 'true');
}

function isDisabled(disabled, root, file) {
  return disabled.has(canonical(root)) || disabled.has(canonical(file));
}

function overrideState(value) {
  if (value === false || value === 'off' || (value && typeof value === 'object' && value.enabled === false)) return 'off';
  if (['on', 'name-only', 'user-invocable-only'].includes(value)) return value;
  return 'on';
}

function discoverSkillRoot(root, metadata, candidates, disabled, warnings) {
  if (!existsDirectory(root)) return;
  if (metadata.projectBoundary && !isWithin(root, metadata.projectBoundary)) {
    warnings.push(`Ignored project skill directory outside the repository: ${root}`);
    return;
  }
  let entries = [];
  if (existsFile(path.join(root, 'SKILL.md'))) entries = [{ name: path.basename(root), root }];
  else {
    try {
      entries = fs.readdirSync(root, { withFileTypes: true })
        .filter((entry) => entry.isDirectory() || entry.isSymbolicLink())
        .map((entry) => ({ name: entry.name, root: path.join(root, entry.name), symbolic: entry.isSymbolicLink() }));
    } catch (error) {
      warnings.push(`Could not read skill directory ${root}: ${error.message}`);
      return;
    }
  }
  for (const entry of entries) {
    const skillFile = path.join(entry.root, 'SKILL.md');
    if (!existsFile(skillFile)) continue;
    if (metadata.skipSources && metadata.skipSources.has(canonical(entry.root))) continue;
    const skillOverride = overrideState(metadata.skillOverrides && metadata.skillOverrides[entry.name]);
    if (skillOverride === 'off') continue;
    const realRoot = canonical(entry.root);
    if (metadata.projectBoundary && entry.symbolic && !isWithin(realRoot, metadata.projectBoundary)) {
      warnings.push(`Ignored project skill symlink outside the repository: ${entry.root}`);
      continue;
    }
    if (isDisabled(disabled, realRoot, skillFile)) continue;
    let markdown;
    try { markdown = fs.readFileSync(skillFile, 'utf8'); }
    catch (error) { warnings.push(`Could not read skill ${skillFile}: ${error.message}`); continue; }
    let identity = skillAlias(entry.name);
    if (metadata.provider === 'codex') {
      const parsed = codexSkillIdentity(markdown);
      if (!parsed.valid) { warnings.push(`Ignored ${skillFile}: ${parsed.reason}`); continue; }
      identity = skillAlias(parsed.name);
    } else if (metadata.pluginRootBoundary && canonical(entry.root) === canonical(metadata.pluginRootBoundary)) {
      identity = skillAlias(yamlTopLevelScalar(markdown, 'name') || entry.name);
    }
    candidates.push({
      ...metadata,
      baseName: identity,
      source: path.resolve(entry.root),
      realSource: realRoot,
      skillFile: path.resolve(skillFile),
      commandFile: null,
      manualOnly: metadata.provider === 'codex' && codexPolicyDisablesImplicit(entry.root),
      overrideState: skillOverride,
      excludePluginRuntime: Boolean(metadata.pluginRootBoundary && canonical(entry.root) === canonical(metadata.pluginRootBoundary)),
    });
  }
}

function discoverClaudeCommands(root, candidates, warnings, metadata = {}) {
  if (existsFile(root)) {
    if (!/\.md$/i.test(root)) return;
    const commandName = path.basename(root).replace(/\.md$/i, '');
    const skillOverride = overrideState(metadata.skillOverrides && metadata.skillOverrides[commandName]);
    if (skillOverride === 'off') return;
    candidates.push({
      provider: 'claude', kind: metadata.kind || 'claude-command', sourceTag: metadata.sourceTag || 'claude-command',
      priority: metadata.priority || 20, namespace: metadata.namespace || null,
      baseName: skillAlias(commandName), source: root,
      realSource: canonical(root), skillFile: root, commandFile: root, manualOnly: false,
      overrideState: skillOverride,
    });
    return;
  }
  if (!existsDirectory(root)) return;
  let entries;
  try { entries = fs.readdirSync(root, { withFileTypes: true }); }
  catch (error) { warnings.push(`Could not read Claude command directory ${root}: ${error.message}`); return; }
  for (const entry of entries) {
    if (!entry.isFile() || !/\.md$/i.test(entry.name)) continue;
    const commandName = entry.name.replace(/\.md$/i, '');
    const skillOverride = overrideState(metadata.skillOverrides && metadata.skillOverrides[commandName]);
    if (skillOverride === 'off') continue;
    const commandFile = path.join(root, entry.name);
    candidates.push({
      provider: 'claude', kind: metadata.kind || 'claude-command', sourceTag: metadata.sourceTag || 'claude-command',
      priority: metadata.priority || 20, namespace: metadata.namespace || null,
      baseName: skillAlias(commandName), source: commandFile,
      realSource: canonical(commandFile), skillFile: commandFile, commandFile, manualOnly: false,
      overrideState: skillOverride,
    });
  }
}

function discoverNativeNamesAt(root, names) {
  const skills = path.join(root, 'skills');
  if (existsDirectory(skills)) {
    try {
      for (const entry of fs.readdirSync(skills, { withFileTypes: true })) {
        if ((entry.isDirectory() || entry.isSymbolicLink()) && existsFile(path.join(skills, entry.name, 'SKILL.md'))) {
          names.add(skillAlias(entry.name).toLocaleLowerCase());
        }
      }
    } catch { }
  }
  const commands = path.join(root, 'commands');
  if (existsDirectory(commands)) {
    try {
      for (const entry of fs.readdirSync(commands, { withFileTypes: true })) {
        if (entry.isFile() && /\.md$/i.test(entry.name)) names.add(skillAlias(entry.name.replace(/\.md$/i, '')).toLocaleLowerCase());
      }
    } catch { }
  }
}

function discoverNativeProjectNames(directories) {
  const names = new Set();
  discoverNativeNamesAt(configDir, names);
  for (const directory of directories) discoverNativeNamesAt(path.join(directory, '.claude'), names);
  return names;
}

function discoverNativePluginNames() {
  const names = new Set();
  const registry = readJson(path.join(configDir, 'plugins', 'installed_plugins.json'), {});
  const plugins = registry && typeof registry.plugins === 'object' && registry.plugins ? registry.plugins : {};
  for (const [pluginId, installs] of Object.entries(plugins)) {
    names.add(skillAlias(pluginId.split('@')[0], 'plugin'));
    if (!Array.isArray(installs)) continue;
    for (const install of installs) {
      if (!install || typeof install.installPath !== 'string') continue;
      const { value } = pluginManifest(path.resolve(install.installPath), 'claude');
      if (value && value.name) names.add(skillAlias(value.name, 'plugin'));
    }
  }
  return names;
}

function mergedClaudeSettings(projectDir, repoRoot) {
  const settings = { enabledPlugins: {}, skillOverrides: {} };
  const apply = (file) => {
    const value = readJson(file, {});
    if (value && typeof value.enabledPlugins === 'object' && value.enabledPlugins) Object.assign(settings.enabledPlugins, value.enabledPlugins);
    if (value && typeof value.skillOverrides === 'object' && value.skillOverrides) Object.assign(settings.skillOverrides, value.skillOverrides);
  };
  apply(path.join(claudeHome, 'settings.json'));
  for (const directory of ancestry(projectDir, repoRoot).reverse()) {
    apply(path.join(directory, '.claude', 'settings.json'));
    apply(path.join(directory, '.claude', 'settings.local.json'));
  }
  const managed = process.env.CLAUDEX_CLAUDE_MANAGED_SETTINGS_FILE || (isWindows
    ? path.join(process.env.ProgramData || 'C:\\ProgramData', 'ClaudeCode', 'managed-settings.json')
    : process.platform === 'darwin'
      ? '/Library/Application Support/ClaudeCode/managed-settings.json'
      : '/etc/claude-code/managed-settings.json');
  apply(managed);
  return settings;
}

function discoverClaudePersonalSkills(root, settings, candidates, disabled, warnings) {
  const pluginRoots = new Set();
  if (existsDirectory(root)) {
    let entries = [];
    try { entries = fs.readdirSync(root, { withFileTypes: true }); } catch { entries = []; }
    for (const entry of entries) {
      if (!entry.isDirectory() && !entry.isSymbolicLink()) continue;
      const pluginRoot = path.join(root, entry.name);
      if (!existsFile(path.join(pluginRoot, '.claude-plugin', 'plugin.json'))) continue;
      pluginRoots.add(canonical(pluginRoot));
      if (!pluginEnabled) continue;
      const { value: manifest } = pluginManifest(pluginRoot, 'claude');
      const pluginName = (manifest && manifest.name) || entry.name;
      const pluginId = `${pluginName}@skills-dir`;
      const configured = settings.enabledPlugins[pluginId];
      if (configured === false || (configured === undefined && manifest && manifest.defaultEnabled === false)) continue;
      discoverPluginContents(pluginRoot, {
        provider: 'claude', kind: 'claude-skills-plugin', sourceTag: skillAlias(pluginName),
        priority: 15, pluginName,
      }, candidates, disabled, warnings);
    }
  }
  discoverSkillRoot(root, {
    provider: 'claude', kind: 'claude-personal', sourceTag: 'claude', priority: 10,
    skillOverrides: settings.skillOverrides, skipSources: pluginRoots,
  }, candidates, disabled, warnings);
}

function pluginManifest(pluginRoot, provider = 'codex') {
  const codex = path.join(pluginRoot, '.codex-plugin', 'plugin.json');
  const claude = path.join(pluginRoot, '.claude-plugin', 'plugin.json');
  const file = provider === 'claude'
    ? (existsFile(claude) ? claude : codex)
    : (existsFile(codex) ? codex : claude);
  return { file, value: readJson(file, {}) };
}

function pluginSkillRoots(pluginRoot, provider, warnings) {
  const { file: manifestFile, value: manifest } = pluginManifest(pluginRoot, provider);
  let configured = manifest && manifest.skills;
  if (typeof configured === 'string') configured = [configured];
  if (!Array.isArray(configured)) configured = [];
  if (!/\.codex-plugin[\\/]plugin\.json$/i.test(manifestFile || '')) configured = ['skills', ...configured];
  else if (configured.length === 0) configured = ['skills'];
  configured = [...new Set(configured)];
  const roots = [];
  for (const relative of configured) {
    if (typeof relative !== 'string' || path.isAbsolute(relative)) continue;
    const candidate = path.resolve(pluginRoot, relative);
    if (!isWithin(candidate, pluginRoot)) {
      warnings.push(`Ignored plugin skill path outside its plugin: ${relative}`);
      continue;
    }
    if (existsDirectory(candidate)) roots.push(candidate);
  }
  if (existsFile(path.join(pluginRoot, 'SKILL.md'))) roots.unshift(pluginRoot);
  return roots;
}

function discoverPluginContents(pluginRoot, metadata, candidates, disabled, warnings) {
  const { file: manifestFile, value: manifest } = pluginManifest(pluginRoot, metadata.provider);
  const namespace = skillAlias((manifest && manifest.name) || metadata.pluginName || path.basename(pluginRoot), 'plugin');
  for (const root of pluginSkillRoots(pluginRoot, metadata.provider, warnings)) {
    discoverSkillRoot(root, { ...metadata, namespace, pluginName: namespace, pluginRootBoundary: pluginRoot }, candidates, disabled, warnings);
  }
  if (!/\.codex-plugin[\\/]plugin\.json$/i.test(manifestFile || '')) {
    let commandRoots = manifest && manifest.commands;
    if (typeof commandRoots === 'string') commandRoots = [commandRoots];
    if (!Array.isArray(commandRoots)) commandRoots = ['commands'];
    for (const relative of commandRoots) {
      if (typeof relative !== 'string' || path.isAbsolute(relative)) continue;
      const commandRoot = path.resolve(pluginRoot, relative);
      if (isWithin(commandRoot, pluginRoot)) discoverClaudeCommands(commandRoot, candidates, warnings, { ...metadata, namespace });
    }
  }
}

function discoverClaudePlugins(projectDir, repoRoot, candidates, disabled, warnings) {
  if (!pluginEnabled) return;
  const registry = readJson(path.join(claudeHome, 'plugins', 'installed_plugins.json'), {});
  const enabled = mergedClaudeSettings(projectDir, repoRoot).enabledPlugins;
  const plugins = registry && typeof registry.plugins === 'object' && registry.plugins ? registry.plugins : {};
  for (const [pluginId, installs] of Object.entries(plugins)) {
    if (!Array.isArray(installs)) continue;
    for (const install of installs) {
      if (!install || typeof install !== 'object') { warnings.push(`Ignored malformed Claude plugin record for ${pluginId}`); continue; }
      const scope = String(install.scope || 'user');
      if (scope !== 'user' && scope !== 'managed') {
        if (typeof install.projectPath !== 'string' || !isWithin(projectDir, install.projectPath)) continue;
      }
      const installPath = typeof install.installPath === 'string' ? path.resolve(install.installPath) : null;
      if (!installPath || !existsDirectory(installPath)) continue;
      const { value: manifest } = pluginManifest(installPath, 'claude');
      if (enabled[pluginId] === false || (enabled[pluginId] === undefined && manifest && manifest.defaultEnabled === false)) continue;
      discoverPluginContents(installPath, {
        provider: 'claude', kind: 'claude-plugin', sourceTag: skillAlias(pluginId.split('@')[0]),
        priority: 70, pluginName: pluginId.split('@')[0],
      }, candidates, disabled, warnings);
    }
  }
}

function codexPluginInventory(warnings) {
  if (!pluginEnabled) return [];
  if (process.env.CLAUDEX_TEST_CODEX_PLUGIN_LIST_FILE) {
    const fixture = readJson(process.env.CLAUDEX_TEST_CODEX_PLUGIN_LIST_FILE, {});
    const list = Array.isArray(fixture) ? fixture : fixture && fixture.installed;
    return Array.isArray(list) ? list : [];
  }
  let result;
  try {
    result = childProcess.spawnSync('codex', ['plugin', 'list', '--json'], {
      encoding: 'utf8', timeout: 5000, maxBuffer: 16 * 1024 * 1024,
      windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'],
    });
  } catch (error) {
    warnings.push(`Could not inspect Codex plugins: ${error.message}`);
    return [];
  }
  if (result.error || result.status !== 0) {
    warnings.push('Could not inspect enabled Codex plugins; standalone Codex skills are still available.');
    return [];
  }
  try {
    const parsed = JSON.parse(result.stdout);
    const list = Array.isArray(parsed) ? parsed : parsed && parsed.installed;
    if (!Array.isArray(list)) throw new Error('inventory is not an array');
    return list;
  } catch {
    warnings.push('Codex returned an invalid plugin inventory; standalone Codex skills are still available.');
    return [];
  }
}

function discoverCodexPlugins(candidates, disabled, warnings) {
  const inventory = codexPluginInventory(warnings);
  const cacheRoot = path.join(codexHome, 'plugins', 'cache');
  for (const plugin of inventory) {
    if (!plugin || typeof plugin !== 'object') { warnings.push('Ignored malformed Codex plugin record.'); continue; }
    if (plugin.installed === false || plugin.enabled === false) continue;
    const marketplace = safeCacheSegment(plugin.marketplaceName || 'plugin');
    const rawPluginName = plugin.name || String(plugin.pluginId || '').split('@')[0] || 'plugin';
    const cachePluginName = safeCacheSegment(rawPluginName);
    const version = safeCacheSegment(plugin.version || 'local');
    const roots = [];
    if (marketplace && cachePluginName && version) roots.push(path.join(cacheRoot, marketplace, cachePluginName, version));
    if (plugin.source && typeof plugin.source.path === 'string' && path.isAbsolute(plugin.source.path)) roots.push(plugin.source.path);
    const pluginRoot = roots.find(existsDirectory);
    if (!pluginRoot) continue;
    discoverPluginContents(pluginRoot, {
      provider: 'codex', kind: 'codex-plugin', sourceTag: skillAlias(rawPluginName),
      priority: 80, pluginName: rawPluginName,
    }, candidates, disabled, warnings);
  }
}

function uniqueCandidates(candidates) {
  const seen = new Set();
  const result = [];
  for (const candidate of candidates.sort((a, b) => a.priority - b.priority || a.source.localeCompare(b.source))) {
    const key = `${candidate.realSource}\u0000${candidate.namespace || ''}\u0000${candidate.baseName.toLocaleLowerCase()}`;
    if (seen.has(key)) continue;
    seen.add(key);
    result.push(candidate);
  }
  return result;
}

function allocateAlias(used, requested) {
  const base = skillAlias(requested);
  let alias = base;
  let suffix = 2;
  while (used.has(alias.toLocaleLowerCase())) alias = `${base.slice(0, Math.max(1, 62 - String(suffix).length))}-${suffix++}`;
  used.add(alias.toLocaleLowerCase());
  return alias;
}

function assignAliases(candidates, nativeNames) {
  const groups = new Map();
  for (const candidate of candidates.filter((item) => !item.namespace)) {
    const key = candidate.baseName.toLocaleLowerCase();
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(candidate);
  }
  const used = new Set(nativeNames);
  const mappings = [];
  for (const group of groups.values()) {
    const preferred = group[0].baseName;
    const nativeCollision = nativeNames.has(preferred.toLocaleLowerCase());
    if (!nativeCollision) mappings.push({ alias: allocateAlias(used, preferred), candidate: group[0], collisionAlias: false });
    if (nativeCollision || group.length > 1) {
      for (const candidate of group) {
        mappings.push({ alias: allocateAlias(used, `${candidate.sourceTag}-${candidate.baseName}`), candidate, collisionAlias: true });
      }
    }
  }
  return mappings.sort((a, b) => a.alias.localeCompare(b.alias));
}

function assignPluginAliases(candidates, nativePluginNames = new Set()) {
  const namespaces = new Map();
  for (const candidate of candidates.filter((item) => item.namespace)) {
    const namespace = skillAlias(candidate.namespace, 'plugin');
    if (!namespaces.has(namespace)) namespaces.set(namespace, []);
    namespaces.get(namespace).push(candidate);
  }
  const mappings = [];
  for (const [namespace, entries] of namespaces) {
    const publishedNamespace = nativePluginNames.has(namespace)
      ? allocateAlias(nativePluginNames, `imported-${namespace}`)
      : allocateAlias(nativePluginNames, namespace);
    const used = new Set();
    const groups = new Map();
    for (const candidate of entries) {
      const key = candidate.baseName.toLocaleLowerCase();
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(candidate);
    }
    for (const group of groups.values()) {
      mappings.push({ namespace: publishedNamespace, alias: allocateAlias(used, group[0].baseName), candidate: group[0], collisionAlias: false });
      if (group.length > 1) {
        for (const candidate of group.slice(1)) {
          mappings.push({ namespace: publishedNamespace, alias: allocateAlias(used, `${candidate.sourceTag}-${candidate.baseName}`), candidate, collisionAlias: true });
        }
      }
    }
  }
  return mappings.sort((a, b) => `${a.namespace}:${a.alias}`.localeCompare(`${b.namespace}:${b.alias}`));
}

function sensitivePath(relative) {
  const normalized = relative.replace(/\\/g, '/').toLocaleLowerCase();
  const base = path.posix.basename(normalized);
  if (base === '.env' || (/^\.env\./.test(base) && !/\.(?:example|sample|template)$/.test(base))) return true;
  if (['.npmrc', '.pypirc', '.netrc', 'credentials', 'id_rsa', 'id_ed25519'].includes(base)) return true;
  return normalized.endsWith('/.aws/credentials') || normalized.endsWith('/.config/gcloud/application_default_credentials.json');
}

function sensitiveContent(buffer) {
  return /-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----/.test(buffer.toString('utf8'));
}

function scanTree(sourceRoot, excludePluginRuntime = false) {
  const root = canonical(sourceRoot);
  if (!existsDirectory(root)) throw new Error(`skill source is not a directory: ${sourceRoot}`);
  const files = [];
  let totalBytes = 0;
  const activeDirectories = new Set();

  const walk = (physicalDirectory, logicalPrefix, depth) => {
    if (depth > MAX_DEPTH) throw new Error(`skill tree exceeds ${MAX_DEPTH} levels`);
    const realDirectory = canonical(physicalDirectory);
    if (!isWithin(realDirectory, root)) throw new Error(`skill support path escapes its root: ${logicalPrefix || '.'}`);
    if (activeDirectories.has(realDirectory)) throw new Error(`skill tree contains a directory cycle: ${logicalPrefix || '.'}`);
    activeDirectories.add(realDirectory);
    let entries = fs.readdirSync(physicalDirectory, { withFileTypes: true });
    entries = entries.sort((a, b) => a.name.localeCompare(b.name));
    for (const entry of entries) {
      const logical = logicalPrefix ? path.join(logicalPrefix, entry.name) : entry.name;
      if (excludePluginRuntime && !logicalPrefix && [
        '.claude-plugin', '.codex-plugin', '.mcp.json', 'agents', 'commands', 'hooks', 'settings.json', 'skills',
      ].includes(entry.name.toLocaleLowerCase())) continue;
      const physical = path.join(physicalDirectory, entry.name);
      const stat = fs.lstatSync(physical);
      let resolved = physical;
      let targetStat = stat;
      if (stat.isSymbolicLink()) {
        resolved = canonical(physical);
        if (!isWithin(resolved, root)) throw new Error(`skill support symlink escapes its root: ${logical}`);
        targetStat = fs.statSync(resolved);
      }
      if (targetStat.isDirectory()) {
        walk(resolved, logical, depth + 1);
        continue;
      }
      if (!targetStat.isFile()) throw new Error(`skill tree contains unsupported file type: ${logical}`);
      if (sensitivePath(logical)) throw new Error(`skill tree contains a sensitive file: ${logical}`);
      if (targetStat.size > MAX_FILE_BYTES) throw new Error(`skill file exceeds ${MAX_FILE_BYTES} bytes: ${logical}`);
      if (files.length + 1 > MAX_FILES) throw new Error(`skill tree exceeds ${MAX_FILES} files`);
      totalBytes += targetStat.size;
      if (totalBytes > MAX_TREE_BYTES) throw new Error(`skill tree exceeds ${MAX_TREE_BYTES} bytes`);
      const fingerprint = cachedFileFingerprint(resolved, targetStat);
      if (fingerprint.sensitive) throw new Error(`skill tree contains private-key material: ${logical}`);
      files.push({
        relative: logical.split(path.sep).join('/'), source: resolved, size: targetStat.size,
        mode: targetStat.mode & 0o777, digest: fingerprint.digest,
      });
    }
    activeDirectories.delete(realDirectory);
  };
  walk(root, '', 0);
  const signature = crypto.createHash('sha256').update(JSON.stringify(files.map(({ relative, size, mode, digest }) => ({
    relative, size, mode, digest,
  })))).digest('hex');
  return { root, files, signature };
}

function prepareCandidates(candidates, warnings) {
  const prepared = [];
  for (const candidate of candidates) {
    try {
      if (candidate.commandFile) {
        const bytes = fs.readFileSync(candidate.commandFile);
        if (bytes.length > MAX_FILE_BYTES || sensitiveContent(bytes)) throw new Error('legacy command exceeds safety limits');
        candidate.tree = {
          root: path.dirname(candidate.commandFile),
          files: [{ relative: 'SKILL.md', source: candidate.commandFile, size: bytes.length, mode: 0o600, digest: crypto.createHash('sha256').update(bytes).digest('hex') }],
          signature: crypto.createHash('sha256').update(bytes).digest('hex'),
        };
      } else candidate.tree = scanTree(candidate.source, candidate.excludePluginRuntime);
      prepared.push(candidate);
    } catch (error) {
      warnings.push(`Ignored unsafe or unreadable skill ${candidate.source}: ${error.message}`);
    }
  }
  return prepared;
}

function verifiedBytes(file) {
  const bytes = fs.readFileSync(file.source);
  const digest = crypto.createHash('sha256').update(bytes).digest('hex');
  if (bytes.length !== file.size || digest !== file.digest) throw new SourceChangedError(`skill changed while staging: ${file.relative}`);
  return bytes;
}

function writeExclusive(file, bytes, mode) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  fs.writeFileSync(file, bytes, { flag: 'wx', mode: mode || 0o600 });
  if (!isWindows) fs.chmodSync(file, mode || 0o600);
}

function adaptedMarkdown(candidate, alias, modelMappings) {
  const skillEntry = candidate.tree.files.find((file) => file.relative.toLocaleLowerCase() === 'skill.md');
  if (!skillEntry) throw new Error(`skill has no SKILL.md snapshot: ${candidate.source}`);
  let markdown = verifiedBytes(skillEntry).toString('utf8');
  if (candidate.commandFile && !frontmatter(markdown)) markdown = `---\ndescription: Imported Claude command ${alias}\n---\n\n${markdown}`;
  markdown = setFrontmatterField(markdown, 'name', alias);
  if (candidate.overrideState === 'name-only') {
    markdown = setFrontmatterField(markdown, 'description', '""');
    markdown = setFrontmatterField(markdown, 'when_to_use', '""');
  }
  const remapped = remapClaudeModel(markdown);
  markdown = remapped.markdown;
  if (candidate.manualOnly || candidate.overrideState === 'user-invocable-only') markdown = ensureManualOnly(markdown);
  modelMappings.push(...remapped.mappings.map((mapping) => ({ ...mapping, source: candidate.source })));
  return markdown;
}

function materializeCandidate(mapping, destination, modelMappings) {
  fs.mkdirSync(destination, { recursive: true, mode: 0o700 });
  writeExclusive(path.join(destination, 'SKILL.md'), Buffer.from(adaptedMarkdown(mapping.candidate, mapping.alias, modelMappings)), 0o600);
  if (mapping.candidate.commandFile) return;
  for (const file of mapping.candidate.tree.files) {
    if (file.relative.toLocaleLowerCase() === 'skill.md') continue;
    const target = path.resolve(destination, ...file.relative.split('/'));
    const relativeTarget = path.relative(path.resolve(destination), target);
    if (relativeTarget === '..' || relativeTarget.startsWith(`..${path.sep}`) || path.isAbsolute(relativeTarget)) {
      throw new Error(`invalid skill support path: ${file.relative}`);
    }
    writeExclusive(target, verifiedBytes(file), file.mode);
  }
}

function sourceSignature(mapping) {
  return {
    alias: mapping.alias, namespace: mapping.namespace || null,
    source: mapping.candidate.realSource, kind: mapping.candidate.kind,
    tree: mapping.candidate.tree.signature, manualOnly: mapping.candidate.manualOnly,
    overrideState: mapping.candidate.overrideState || 'on',
  };
}

function discover(projectDir) {
  const warnings = [];
  const candidates = [];
  const repoRoot = findRepoRoot(projectDir);
  const directories = ancestry(projectDir, repoRoot);
  const disabled = parseDisabledCodexSkills(projectDir, repoRoot);
  const claudeSettings = mergedClaudeSettings(projectDir, repoRoot);
  const nativeNames = discoverNativeProjectNames(directories);
  const nativePluginNames = discoverNativePluginNames();
  nativePluginNames.add('claudex-codex-skill-references');

  discoverClaudePersonalSkills(path.join(claudeHome, 'skills'), claudeSettings, candidates, disabled, warnings);
  discoverClaudeCommands(path.join(claudeHome, 'commands'), candidates, warnings, {
    skillOverrides: claudeSettings.skillOverrides,
  });

  directories.forEach((directory, index) => {
    discoverSkillRoot(path.join(directory, '.agents', 'skills'), {
      provider: 'codex', kind: 'codex-project', sourceTag: index === 0 ? 'codex-project' : `codex-parent-${index}`,
      priority: 30 + index, projectBoundary: repoRoot,
    }, candidates, disabled, warnings);
    discoverSkillRoot(path.join(directory, '.codex', 'skills'), {
      provider: 'codex', kind: 'codex-project-legacy', sourceTag: index === 0 ? 'codex-project-legacy' : `codex-parent-legacy-${index}`,
      priority: 40 + index, projectBoundary: repoRoot,
    }, candidates, disabled, warnings);
  });

  discoverSkillRoot(path.join(home, '.agents', 'skills'), {
    provider: 'codex', kind: 'codex-user', sourceTag: 'codex', priority: 50,
  }, candidates, disabled, warnings);
  discoverSkillRoot(path.join(codexHome, 'skills'), {
    provider: 'codex', kind: 'codex-legacy', sourceTag: 'codex-legacy', priority: 60,
  }, candidates, disabled, warnings);
  const adminRoot = process.env.CLAUDEX_CODEX_ADMIN_SKILLS_DIR || (isWindows
    ? path.join(process.env.ProgramData || 'C:\\ProgramData', 'Codex', 'skills')
    : '/etc/codex/skills');
  discoverSkillRoot(adminRoot, {
    provider: 'codex', kind: 'codex-admin', sourceTag: 'codex-admin', priority: 65,
  }, candidates, disabled, warnings);

  for (const extra of String(process.env.CLAUDEX_SKILL_EXTRA_DIRS || '').split(path.delimiter).filter(Boolean)) {
    discoverSkillRoot(path.resolve(expandHome(extra)), {
      provider: 'shared', kind: 'extra', sourceTag: 'extra', priority: 66,
    }, candidates, disabled, warnings);
  }

  discoverClaudePlugins(projectDir, repoRoot, candidates, disabled, warnings);
  discoverCodexPlugins(candidates, disabled, warnings);
  const unique = uniqueCandidates(prepareCandidates(candidates, warnings));
  return {
    mappings: assignAliases(unique, nativeNames),
    pluginMappings: assignPluginAliases(unique, nativePluginNames),
    warnings,
    repoRoot,
  };
}

function promptHookSource() {
  return `'use strict';
const fs = require('fs');
const path = require('path');
const MAX_INPUT = 1048576;
const MAX_CONTEXT = 65536;
const MAX_SKILL = 32768;
const bytes = (value) => Buffer.byteLength(value, 'utf8');
const truncateBytes = (value, limit) => {
  if (bytes(value) <= limit) return value;
  let result = Buffer.from(value, 'utf8').subarray(0, limit).toString('utf8');
  if (result.endsWith('\\uFFFD')) result = result.slice(0, -1);
  return result;
};
let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => { if (bytes(input) < MAX_INPUT) input = truncateBytes(input + chunk, MAX_INPUT); });
process.stdin.on('end', () => {
  try {
    const event = JSON.parse(input || '{}');
    const prompt = String(event.prompt || '');
    const map = JSON.parse(fs.readFileSync(path.join(__dirname, 'skill-map.json'), 'utf8'));
    const names = [];
    const reference = /(^|[^A-Za-z0-9_$\\\\])\\$([a-z0-9]+(?:-[a-z0-9]+)*(?::[a-z0-9]+(?:-[a-z0-9]+)*)?)(?=$|[\\s.,;!?()[\\]{}"'])/gi;
    let match;
    while ((match = reference.exec(prompt)) !== null) {
      const key = match[2].toLowerCase();
      if (map[key] && !names.includes(key)) names.push(key);
    }
    if (!names.length) return;
    let context = '';
    const omitted = [];
    for (const name of names) {
      const item = map[name];
      let markdown = fs.readFileSync(item.file, 'utf8');
      const frontmatter = markdown.match(/^(?:\\uFEFF?---)(?:\\r?\\n)[\\s\\S]*?(?:\\r?\\n)---[ \\t]*(?:\\r?\\n|$)/);
      if (frontmatter) markdown = markdown.slice(frontmatter[0].length);
      if (bytes(markdown) > MAX_SKILL) {
        const recovery = '\\n[Skill truncated; read the complete file at ' + item.file + ']';
        markdown = truncateBytes(markdown, MAX_SKILL - bytes(recovery)) + recovery;
      }
      const block = '\\nThe user explicitly referenced Codex skill $' + name + '. Apply these instructions. Skill directory: ' + item.directory + '\\n<codex-skill name="' + name + '">\\n' + markdown + '\\n</codex-skill>\\n';
      if (bytes(context) + bytes(block) > MAX_CONTEXT) {
        omitted.push('$' + name + ' (' + item.file + ')');
        continue;
      }
      context += block;
    }
    if (omitted.length) {
      const note = '\\nAdditional explicitly referenced skills exceeded the context limit; read their complete files before applying them: ' + omitted.join(', ') + '\\n';
      context = truncateBytes(context + note, MAX_CONTEXT);
    }
    process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: 'UserPromptSubmit', additionalContext: context } }));
  } catch (error) {
    process.stderr.write('Claudex skill reference hook: ' + error.message + '\\n');
  }
});
`;
}

function materializeDollarReferencePlugin(stage, references) {
  if (!dollarReferencesEnabled || references.length === 0) return null;
  const relative = path.join('plugins', 'claudex-codex-skill-references');
  const root = path.join(stage, relative);
  writeExclusive(path.join(root, '.claude-plugin', 'plugin.json'), Buffer.from(`${JSON.stringify({ name: 'claudex-codex-skill-references', version: '1.0.0', description: 'Claudex Codex skill reference compatibility' }, null, 2)}\n`), 0o600);
  writeExclusive(path.join(root, 'hooks', 'hooks.json'), Buffer.from(`${JSON.stringify({ hooks: { UserPromptSubmit: [{ hooks: [{ type: 'command', command: 'node "${CLAUDE_PLUGIN_ROOT}/scripts/prompt-hook.cjs"', timeout: 5 }] }] } }, null, 2)}\n`), 0o600);
  writeExclusive(path.join(root, 'scripts', 'prompt-hook.cjs'), Buffer.from(promptHookSource()), 0o700);
  writeExclusive(path.join(root, 'scripts', 'skill-map.json'), Buffer.from(`${JSON.stringify(Object.fromEntries(references), null, 2)}\n`), 0o600);
  return relative;
}

function generationResult(generation, manifest, extraWarnings = [], currentWarnings = manifest.warnings || []) {
  const pluginDirs = (manifest.pluginRelativeDirs || []).map((relative) => path.join(generation, ...relative.split('/')));
  return {
    schema: BRIDGE_SCHEMA, enabled: true, overlay: generation, addDirs: [generation], pluginDirs,
    skills: manifest.skills || [], modelMappings: manifest.modelMappings || [],
    warnings: [...currentWarnings, ...extraWarnings],
  };
}

function validManifest(file, expectedPolicyFingerprint = null) {
  const manifest = readJson(file, null);
  if (!manifest || manifest.schema !== BRIDGE_SCHEMA || manifest.format !== BRIDGE_FORMAT
      || !Array.isArray(manifest.skills) || !Array.isArray(manifest.pluginRelativeDirs)) return null;
  if (expectedPolicyFingerprint && manifest.policyFingerprint !== expectedPolicyFingerprint) return null;
  const generation = path.dirname(file);
  for (const relative of manifest.pluginRelativeDirs) {
    if (typeof relative !== 'string' || !relative) return null;
    const pluginDirectory = path.resolve(generation, ...relative.split('/'));
    if (!isWithin(pluginDirectory, generation) || !existsDirectory(pluginDirectory)
        || !existsFile(path.join(pluginDirectory, '.claude-plugin', 'plugin.json'))) return null;
  }
  for (const skill of manifest.skills) {
    if (!skill || typeof skill.alias !== 'string' || !skill.alias) return null;
    let skillFile;
    if (skill.mode === 'snapshot') {
      if (skill.alias !== skillAlias(skill.alias)) return null;
      skillFile = path.join(generation, '.claude', 'skills', skill.alias, 'SKILL.md');
    } else if (skill.mode === 'snapshot-plugin') {
      const separator = skill.alias.indexOf(':');
      if (separator < 1) return null;
      const namespace = skill.alias.slice(0, separator);
      const alias = skill.alias.slice(separator + 1);
      if (namespace !== skillAlias(namespace, 'plugin') || alias !== skillAlias(alias)) return null;
      skillFile = path.join(generation, 'plugins', namespace, 'skills', alias, 'SKILL.md');
    } else return null;
    if (!isWithin(skillFile, generation) || !existsFile(skillFile)) return null;
  }
  return manifest;
}

function latestPointerPath(generations, projectHash, policyFingerprint) {
  return path.join(generations, `.latest-${projectHash}-${policyFingerprint}.json`);
}

function rememberLatestGeneration(generations, projectHash, policyFingerprint, generation) {
  const pointer = latestPointerPath(generations, projectHash, policyFingerprint);
  try {
    fs.writeFileSync(pointer, `${JSON.stringify({ generation: path.basename(generation) })}\n`, { mode: 0o600 });
  } catch { }
}

function latestGeneration(generations, projectHash, policyFingerprint) {
  if (!existsDirectory(generations)) return null;
  const pointer = readJson(latestPointerPath(generations, projectHash, policyFingerprint), null);
  if (pointer && typeof pointer.generation === 'string'
      && pointer.generation === path.basename(pointer.generation)
      && pointer.generation.startsWith(`${projectHash}-`)) {
    const pointed = path.join(generations, pointer.generation);
    const pointedManifest = validManifest(path.join(pointed, 'manifest.json'), policyFingerprint);
    if (pointedManifest) return pointed;
  }
  let entries = [];
  try { entries = fs.readdirSync(generations, { withFileTypes: true }); } catch { return null; }
  const candidates = entries.filter((entry) => entry.isDirectory() && entry.name.startsWith(`${projectHash}-`))
    .map((entry) => {
      const directory = path.join(generations, entry.name);
      const manifest = validManifest(path.join(directory, 'manifest.json'), policyFingerprint);
      return { directory, manifest, publishedAt: Number(manifest && manifest.publishedAt) || fs.statSync(directory).mtimeMs };
    })
    .filter((entry) => entry.manifest)
    .sort((a, b) => b.publishedAt - a.publishedAt || b.directory.localeCompare(a.directory));
  return candidates[0] ? candidates[0].directory : null;
}

function garbageCollect(generations, projectHash, active) {
  const lock = path.join(generations, '.gc.lock');
  try {
    if (existsDirectory(lock) && Date.now() - fs.statSync(lock).mtimeMs >= STALE_GC_LOCK_MS) {
      fs.rmSync(lock, { recursive: true, force: true });
    }
  } catch { }
  try { fs.mkdirSync(lock); } catch { return; }
  try {
    const now = Date.now();
    const directoryEntries = fs.readdirSync(generations, { withFileTypes: true });
    for (const entry of directoryEntries) {
      if (!entry.isDirectory() || !/^\.gc-.+\.lock$/.test(entry.name)) continue;
      const legacyLock = path.join(generations, entry.name);
      if (now - fs.statSync(legacyLock).mtimeMs >= STALE_GC_LOCK_MS) {
        fs.rmSync(legacyLock, { recursive: true, force: true });
      }
    }
    const stages = directoryEntries
      .filter((entry) => entry.isDirectory() && entry.name.startsWith('.stage-'))
      .map((entry) => path.join(generations, entry.name))
      .sort((a, b) => fs.statSync(b).mtimeMs - fs.statSync(a).mtimeMs);
    for (const [index, stage] of stages.entries()) {
      if (index >= MAX_STAGE_DIRECTORIES || now - fs.statSync(stage).mtimeMs >= STALE_STAGE_MS) {
        fs.rmSync(stage, { recursive: true, force: true });
      }
    }

    const valid = [];
    for (const entry of directoryEntries) {
      if (!entry.isDirectory() || entry.name.startsWith('.')) continue;
      const directory = path.join(generations, entry.name);
      const manifest = validManifest(path.join(directory, 'manifest.json'));
      if (!manifest) {
        if (entry.name.startsWith(`${projectHash}-`) && directory !== active) {
          fs.rmSync(directory, { recursive: true, force: true });
        }
        continue;
      }
      valid.push({ directory, mtimeMs: fs.statSync(directory).mtimeMs });
    }
    valid.sort((a, b) => b.mtimeMs - a.mtimeMs || b.directory.localeCompare(a.directory));

    const projectEntries = valid.filter((entry) => path.basename(entry.directory).startsWith(`${projectHash}-`));
    const projectKeep = new Set([active]);
    for (const entry of projectEntries) {
      if (projectKeep.size >= MAX_GENERATIONS_PER_PROJECT) break;
      projectKeep.add(entry.directory);
    }
    for (const entry of projectEntries) {
      if (!projectKeep.has(entry.directory)) fs.rmSync(entry.directory, { recursive: true, force: true });
    }

    const remaining = valid.filter((entry) => existsDirectory(entry.directory));
    const globalKeep = new Set([active]);
    for (const entry of remaining) {
      if (globalKeep.size >= MAX_TOTAL_GENERATIONS) break;
      globalKeep.add(entry.directory);
    }
    for (const entry of remaining) {
      if (!globalKeep.has(entry.directory)) fs.rmSync(entry.directory, { recursive: true, force: true });
    }

    for (const entry of fs.readdirSync(generations, { withFileTypes: true })) {
      if (!entry.isFile() || !entry.name.startsWith('.latest-')) continue;
      const pointerPath = path.join(generations, entry.name);
      const pointer = readJson(pointerPath, null);
      if (!pointer || typeof pointer.generation !== 'string'
          || pointer.generation !== path.basename(pointer.generation)
          || !validManifest(path.join(generations, pointer.generation, 'manifest.json'))) {
        fs.rmSync(pointerPath, { force: true });
      }
    }
  } catch { }
  finally { try { fs.rmdirSync(lock); } catch { } }
}

function syncOnce(projectDir) {
  const discovered = discover(projectDir);
  const allMappings = [...discovered.mappings, ...discovered.pluginMappings];
  const sortObjects = (values) => values.sort((left, right) => {
    const leftKey = JSON.stringify(left);
    const rightKey = JSON.stringify(right);
    return leftKey < rightKey ? -1 : leftKey > rightKey ? 1 : 0;
  });
  const signatures = sortObjects(allMappings.map(sourceSignature));
  const policySkills = sortObjects(allMappings.map((mapping) => ({
    alias: mapping.alias, namespace: mapping.namespace || null, source: mapping.candidate.realSource,
    kind: mapping.candidate.kind, provider: mapping.candidate.provider, manualOnly: mapping.candidate.manualOnly,
    overrideState: mapping.candidate.overrideState || 'on',
  })));
  const policyFingerprint = crypto.createHash('sha256').update(JSON.stringify({
    format: BRIDGE_FORMAT, pluginEnabled, dollarReferencesEnabled,
    skills: policySkills,
  })).digest('hex');
  const fingerprint = crypto.createHash('sha256').update(JSON.stringify({
    schema: BRIDGE_SCHEMA, format: BRIDGE_FORMAT, platform: process.platform,
    signatures, dollarReferencesEnabled, policyFingerprint,
  })).digest('hex').slice(0, 20);
  const projectHash = crypto.createHash('sha256').update(canonical(projectDir)).digest('hex').slice(0, 12);
  const generations = path.join(configDir, 'skill-bridge', 'generations');
  const generation = path.join(generations, `${projectHash}-${fingerprint}`);
  const manifestPath = path.join(generation, 'manifest.json');
  let manifest = validManifest(manifestPath, policyFingerprint);
  if (manifest) {
    rememberLatestGeneration(generations, projectHash, policyFingerprint, generation);
    garbageCollect(generations, projectHash, generation);
    return generationResult(generation, manifest, [], discovered.warnings);
  }

  fs.mkdirSync(generations, { recursive: true, mode: 0o700 });
  if (existsDirectory(generation) && !manifest) fs.rmSync(generation, { recursive: true, force: true });
  const stage = path.join(generations, `.stage-${process.pid}-${crypto.randomBytes(6).toString('hex')}`);
  const skillsDir = path.join(stage, '.claude', 'skills');
  fs.mkdirSync(skillsDir, { recursive: true, mode: 0o700 });
  const records = [];
  const modelMappings = [];
  const pluginRelativeDirs = [];
  const dollarReferences = [];
  try {
    for (const mapping of discovered.mappings) {
      const destination = path.join(skillsDir, mapping.alias);
      materializeCandidate(mapping, destination, modelMappings);
      const record = {
        alias: mapping.alias, provider: mapping.candidate.provider, kind: mapping.candidate.kind,
        source: mapping.candidate.source, mode: 'snapshot', collisionAlias: mapping.collisionAlias,
        manualOnly: mapping.candidate.manualOnly,
        overrideState: mapping.candidate.overrideState || 'on',
      };
      records.push(record);
      dollarReferences.push([mapping.alias.toLocaleLowerCase(), {
        file: path.join(generation, '.claude', 'skills', mapping.alias, 'SKILL.md'),
        directory: path.join(generation, '.claude', 'skills', mapping.alias),
      }]);
    }

    const pluginGroups = new Map();
    for (const mapping of discovered.pluginMappings) {
      if (!pluginGroups.has(mapping.namespace)) pluginGroups.set(mapping.namespace, []);
      pluginGroups.get(mapping.namespace).push(mapping);
    }
    for (const [namespace, mappings] of pluginGroups) {
      const relative = path.join('plugins', namespace);
      const pluginRoot = path.join(stage, relative);
      writeExclusive(path.join(pluginRoot, '.claude-plugin', 'plugin.json'), Buffer.from(`${JSON.stringify({
        name: namespace, version: '1.0.0', description: `Imported skill compatibility for ${namespace}`,
      }, null, 2)}\n`), 0o600);
      for (const mapping of mappings) {
        materializeCandidate(mapping, path.join(pluginRoot, 'skills', mapping.alias), modelMappings);
        const fullAlias = `${namespace}:${mapping.alias}`;
        records.push({
          alias: fullAlias, provider: mapping.candidate.provider, kind: mapping.candidate.kind,
          source: mapping.candidate.source, mode: 'snapshot-plugin', collisionAlias: mapping.collisionAlias,
          manualOnly: mapping.candidate.manualOnly,
          overrideState: mapping.candidate.overrideState || 'on',
        });
        dollarReferences.push([fullAlias.toLocaleLowerCase(), {
          file: path.join(generation, 'plugins', namespace, 'skills', mapping.alias, 'SKILL.md'),
          directory: path.join(generation, 'plugins', namespace, 'skills', mapping.alias),
        }]);
      }
      pluginRelativeDirs.push(relative.split(path.sep).join('/'));
    }

    const hookPlugin = materializeDollarReferencePlugin(stage, dollarReferences);
    if (hookPlugin) pluginRelativeDirs.push(hookPlugin.split(path.sep).join('/'));

    for (const mapping of allMappings) {
      const fresh = mapping.candidate.commandFile
        ? crypto.createHash('sha256').update(fs.readFileSync(mapping.candidate.commandFile)).digest('hex')
        : scanTree(mapping.candidate.source, mapping.candidate.excludePluginRuntime).signature;
      if (fresh !== mapping.candidate.tree.signature) throw new SourceChangedError(`skill changed while publishing: ${mapping.candidate.source}`);
    }

    manifest = {
      schema: BRIDGE_SCHEMA, format: BRIDGE_FORMAT, project: path.resolve(projectDir), repoRoot: discovered.repoRoot,
      fingerprint, policyFingerprint, publishedAt: Date.now(), skills: records, pluginRelativeDirs, modelMappings, warnings: discovered.warnings,
    };
    fs.writeFileSync(path.join(stage, 'manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o600, flag: 'wx' });
    if (process.env.NODE_ENV === 'test' && process.env.CLAUDEX_TEST_FAIL_SKILL_PUBLICATION === '1') {
      throw new Error('simulated skill snapshot publication failure');
    }
    try { fs.renameSync(stage, generation); }
    catch (error) {
      const concurrent = validManifest(manifestPath, policyFingerprint);
      if (!concurrent) throw error;
      fs.rmSync(stage, { recursive: true, force: true });
      manifest = concurrent;
    }
  } catch (error) {
    fs.rmSync(stage, { recursive: true, force: true });
    error.policyFingerprint = policyFingerprint;
    error.discoveryWarnings = discovered.warnings;
    throw error;
  }
  rememberLatestGeneration(generations, projectHash, policyFingerprint, generation);
  garbageCollect(generations, projectHash, generation);
  return generationResult(generation, manifest, [], discovered.warnings);
}

function sync(projectDir) {
  if (!bridgeEnabled) return { schema: BRIDGE_SCHEMA, enabled: false, overlay: null, addDirs: [], pluginDirs: [], skills: [], warnings: [] };
  const projectHash = crypto.createHash('sha256').update(canonical(projectDir)).digest('hex').slice(0, 12);
  const generations = path.join(configDir, 'skill-bridge', 'generations');
  let lastError;
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const result = syncOnce(projectDir);
      saveDigestCache();
      return result;
    }
    catch (error) {
      lastError = error;
      if (!(error instanceof SourceChangedError)) break;
    }
  }
  const fallback = lastError && lastError.policyFingerprint
    ? latestGeneration(generations, projectHash, lastError.policyFingerprint)
    : null;
  if (fallback) {
    const manifest = validManifest(path.join(fallback, 'manifest.json'), lastError.policyFingerprint);
    saveDigestCache();
    return generationResult(
      fallback,
      manifest,
      [`Skill refresh failed; using the last known good snapshot: ${lastError.message}`],
      lastError.discoveryWarnings || manifest.warnings || [],
    );
  }
  throw lastError;
}

function printList(result) {
  if (!result.enabled) {
    process.stdout.write('Claudex skill compatibility is disabled (CLAUDEX_SKILL_BRIDGE=off).\n');
    return;
  }
  process.stdout.write(`Claudex skills: ${result.skills.length} bridged aliases, ${result.pluginDirs.length} isolated compatibility plugins\n`);
  for (const skill of result.skills) {
    const qualifier = skill.collisionAlias ? ' (collision alias)' : '';
    process.stdout.write(`/${skill.alias}\t${skill.kind}${qualifier}\t${skill.source}\n`);
  }
  for (const pluginDir of result.pluginDirs) process.stdout.write(`plugin\t${pluginDir}\n`);
  for (const mapping of result.modelMappings || []) process.stdout.write(`model\t${mapping.from} -> ${mapping.to}\t${mapping.source}\n`);
  for (const warning of result.warnings || []) process.stderr.write(`claudex skills: ${warning}\n`);
}

function parseArguments(argv) {
  const command = argv[0] || 'sync';
  let project = process.cwd();
  for (let index = 1; index < argv.length; index++) {
    if (argv[index] === '--project' && argv[index + 1]) project = argv[++index];
    else throw new Error(`unknown argument: ${argv[index]}`);
  }
  return { command, project: path.resolve(project) };
}

function main() {
  const { command, project } = parseArguments(process.argv.slice(2));
  if (!['sync', 'list', 'doctor'].includes(command)) throw new Error(`unknown command: ${command}`);
  const result = sync(project);
  if (command === 'sync') process.stdout.write(`${JSON.stringify(result)}\n`);
  else printList(result);
}

if (require.main === module) {
  try { main(); }
  catch (error) {
    process.stderr.write(`claudex skill bridge: ${error.message}\n`);
    process.exit(1);
  }
}

module.exports = {
  assignAliases, codexPolicyDisablesImplicit, codexSkillIdentity, discover, ensureManualOnly,
  findRepoRoot, frontmatter, parseDisabledCodexSkills, remapClaudeModel, safeName, scanTree, skillAlias, sync,
};
