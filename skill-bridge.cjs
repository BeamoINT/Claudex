#!/usr/bin/env node
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const childProcess = require('child_process');

const BRIDGE_SCHEMA = 3;
const BRIDGE_FORMAT = 'skills-v6-cross-harness-20260716';
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
const DEFAULT_MAX_INSTRUCTION_BYTES = 32 * 1024;
const MAX_WARNING_COUNT = 128;
const MAX_WARNING_BYTES = 2048;
const SCOPE_PROJECT = 'project';
const SCOPE_GLOBAL_ONLY = 'global-only';
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
const instructionBridgeEnabled = (process.env.CLAUDEX_INSTRUCTION_BRIDGE || 'on') !== 'off';

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
  name = name.replace(/[<>:"/\\|?*\u0000-\u001f\u007f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, '-');
  name = name.replace(/[^\p{L}\p{N}._-]+/gu, '-').replace(/-+/g, '-');
  name = name.replace(/^[. -]+|[. -]+$/g, '').slice(0, 64) || fallback;
  if (/^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(name)) name = `skill-${name}`.slice(0, 64);
  return name;
}

function safeWarning(value) {
  let warning = String(value || '').normalize('NFC')
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, '')
    .replace(/[\r\n\t]+/g, ' ').replace(/\s+/g, ' ').trim();
  if (Buffer.byteLength(warning, 'utf8') > MAX_WARNING_BYTES) {
    warning = Buffer.from(warning, 'utf8').subarray(0, MAX_WARNING_BYTES - 3).toString('utf8').replace(/\uFFFD$/, '') + '...';
  }
  return warning;
}

function boundedWarnings(values) {
  const result = [];
  const seen = new Set();
  for (const value of values || []) {
    const warning = safeWarning(value);
    if (!warning || seen.has(warning)) continue;
    seen.add(warning);
    if (result.length >= MAX_WARNING_COUNT) break;
    result.push(warning);
  }
  return result;
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

function instructionAt(directory, boundary, scope, warnings, fallbackFilenames = []) {
  const names = scope === 'global' ? ['AGENTS.override.md', 'AGENTS.md']
    : ['AGENTS.override.md', 'AGENTS.md', ...fallbackFilenames];
  for (const name of names) {
    const candidate = path.join(directory, name);
    let linkStat;
    try { linkStat = fs.lstatSync(candidate); }
    catch { continue; }
    let resolved = candidate;
    let stat = linkStat;
    try {
      resolved = canonical(candidate);
      if (!isWithin(resolved, boundary)) {
        warnings.push(`Ignored Codex instruction symlink outside its ${scope} boundary: ${candidate}`);
        continue;
      }
      if (linkStat.isSymbolicLink()) stat = fs.statSync(resolved);
      if (!stat.isFile()) {
        warnings.push(`Ignored unsupported Codex instruction file: ${candidate}`);
        continue;
      }
      if (stat.size > MAX_FILE_BYTES) {
        warnings.push(`Ignored Codex instruction file larger than ${MAX_FILE_BYTES} bytes: ${candidate}`);
        continue;
      }
      const bytes = fs.readFileSync(resolved);
      if (bytes.length !== stat.size) throw new SourceChangedError(`Codex instructions changed while reading: ${candidate}`);
      if (sensitiveContent(bytes)) {
        warnings.push(`Ignored Codex instruction file containing material that resembles a private key: ${candidate}`);
        continue;
      }
      const rendered = Buffer.from(bytes.toString('utf8').trim(), 'utf8');
      if (rendered.length === 0) continue;
      return {
        scope, directory: path.resolve(directory), name, source: path.resolve(candidate), realSource: resolved,
        size: bytes.length, digest: crypto.createHash('sha256').update(bytes).digest('hex'), renderedSize: rendered.length,
      };
    } catch (error) {
      if (error instanceof SourceChangedError) throw error;
      warnings.push(`Could not read Codex instruction file ${candidate}: ${error.message}`);
    }
  }
  return null;
}

function discoverInstructions(projectDir, repoRoot, warnings, config = effectiveCodexProjectConfig(projectDir, repoRoot), globalOnly = false) {
  if (!instructionBridgeEnabled) return {
    files: [], signature: 'off', renderedBytes: 0, truncated: false,
    maxBytes: config.projectDocMaxBytes, fallbackFilenames: config.fallbackFilenames,
    projectTrusted: config.projectTrusted,
  };
  const files = [];
  const global = instructionAt(codexHome, codexHome, 'global', warnings);
  if (global) files.push(global);
  if (!globalOnly) {
    for (const directory of ancestry(projectDir, repoRoot).reverse()) {
      const project = instructionAt(directory, repoRoot, 'project', warnings, config.fallbackFilenames);
      if (project) files.push(project);
    }
  }

  let renderedBytes = 0;
  let truncated = false;
  let remaining = config.projectDocMaxBytes;
  let hasContent = false;
  // Match Codex's forward concatenation contract exactly: global first, then
  // repository root toward the current directory, stopping at the byte cap.
  for (const file of files) {
    const separatorBytes = hasContent ? 2 : 0;
    const available = Math.max(0, remaining - separatorBytes);
    file.includedBytes = Math.min(file.renderedSize, available);
    file.truncated = file.includedBytes < file.renderedSize;
    if (file.includedBytes > 0) {
      renderedBytes += separatorBytes + file.includedBytes;
      remaining -= separatorBytes + file.includedBytes;
      hasContent = true;
    }
    if (file.truncated || file.includedBytes === 0) truncated = true;
  }
  if (truncated) warnings.push(`Codex instructions exceeded ${config.projectDocMaxBytes} bytes and were truncated in the compatibility snapshot.`);
  const signature = crypto.createHash('sha256').update(JSON.stringify({
    files: files.map((file) => ({
      scope: file.scope, source: file.realSource, size: file.size, digest: file.digest,
      renderedSize: file.renderedSize, includedBytes: file.includedBytes,
    })),
    maxBytes: config.projectDocMaxBytes,
    fallbackFilenames: config.fallbackFilenames,
    projectTrusted: config.projectTrusted,
  })).digest('hex');
  return {
    files, signature, renderedBytes, truncated, maxBytes: config.projectDocMaxBytes,
    fallbackFilenames: config.fallbackFilenames, projectTrusted: config.projectTrusted,
  };
}

function decodeQuotedScalar(raw) {
  const value = String(raw || '').trim();
  if (value.startsWith('"') && value.endsWith('"')) {
    try { return JSON.parse(value); } catch { return value.slice(1, -1); }
  }
  if (value.startsWith("'") && value.endsWith("'")) return value.slice(1, -1).replace(/''/g, "'");
  const comment = value.search(/[ \t]#/);
  return (comment >= 0 ? value.slice(0, comment) : value).trim();
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
  const expected = String(key).toLowerCase();
  for (const line of parsed.body.split(/\r?\n/)) {
    const entry = yamlMappingEntry(line);
    if (!entry || entry.indent !== 0 || entry.key.toLowerCase() !== expected) continue;
    const scalar = entry.value.trimStart();
    return scalar ? decodeQuotedScalar(scalar) : null;
  }
  return null;
}

function replaceFrontmatterField(markdown, key, value) {
  const parsed = frontmatter(markdown);
  if (!parsed) return markdown;
  const line = `${key}: ${value}`;
  const lines = parsed.body.split(/\r?\n/);
  const index = lines.findIndex((entry) => {
    const mapping = yamlMappingEntry(entry);
    return mapping && mapping.indent === 0 && mapping.key.toLowerCase() === String(key).toLowerCase();
  });
  if (index >= 0) {
    const scalar = yamlMappingEntry(lines[index]).value.trim();
    let end = index + 1;
    if (scalar === '' || /^[>|][+-]?[0-9]*$/.test(scalar)) {
      while (end < lines.length && (lines[end].trim() === '' || /^\s+/.test(lines[end]))) end++;
    }
    lines.splice(index, end - index, line);
  } else lines.unshift(line);
  const body = lines.join(parsed.eol);
  return `${parsed.open}${parsed.eol}${body}${parsed.closePrefix}---${parsed.closeEol}${parsed.rest}`;
}

function yamlMappingEntry(line) {
  const text = String(line || '');
  const indentMatch = text.match(/^ */);
  const indent = indentMatch ? indentMatch[0].length : 0;
  let quote = null;
  let escaped = false;
  for (let index = indent; index < text.length; index += 1) {
    const character = text[index];
    if (escaped) { escaped = false; continue; }
    if (quote === '"' && character === '\\') { escaped = true; continue; }
    if (quote) { if (character === quote) quote = null; continue; }
    if (character === '"' || character === "'") { quote = character; continue; }
    if (character !== ':') continue;
    const rawKey = text.slice(indent, index).trim();
    if (!rawKey) return null;
    let decoded = rawKey;
    if ((rawKey.startsWith('"') && rawKey.endsWith('"')) || (rawKey.startsWith("'") && rawKey.endsWith("'"))) {
      decoded = decodeQuotedScalar(rawKey);
    }
    if (typeof decoded !== 'string') return null;
    return { indent, key: decoded, value: text.slice(index + 1) };
  }
  return null;
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

function tomlKey(raw) {
  const value = String(raw || '').trim();
  return value.startsWith('"') || value.startsWith("'") ? tomlString(value) : /^[A-Za-z0-9_-]+$/.test(value) ? value : null;
}

function splitTomlDottedKey(raw) {
  const parts = [];
  let start = 0;
  let quote = null;
  let escaped = false;
  const text = String(raw || '').trim();
  for (let index = 0; index <= text.length; index += 1) {
    const character = text[index];
    if (escaped) { escaped = false; continue; }
    if (quote === '"' && character === '\\') { escaped = true; continue; }
    if (quote) { if (character === quote) quote = null; continue; }
    if (character === '"' || character === "'") { quote = character; continue; }
    if (character !== '.' && index !== text.length) continue;
    const part = tomlKey(text.slice(start, index));
    if (part === null) return null;
    parts.push(part);
    start = index + 1;
  }
  return parts;
}

function stripTomlComment(raw) {
  let quote = null;
  let escaped = false;
  const text = String(raw || '');
  let result = '';
  let comment = false;
  for (let index = 0; index < text.length; index += 1) {
    const character = text[index];
    if (comment) {
      if (character === '\n') { comment = false; result += character; }
      continue;
    }
    if (escaped) { escaped = false; result += character; continue; }
    if (quote === '"' && character === '\\') { escaped = true; result += character; continue; }
    if (quote) { if (character === quote) quote = null; result += character; continue; }
    if (character === '"' || character === "'") { quote = character; result += character; continue; }
    if (character === '#') { comment = true; continue; }
    result += character;
  }
  return result.trim();
}

function tomlAssignment(line) {
  let quote = null;
  let escaped = false;
  for (let index = 0; index < line.length; index += 1) {
    const character = line[index];
    if (escaped) { escaped = false; continue; }
    if (quote === '"' && character === '\\') { escaped = true; continue; }
    if (quote) { if (character === quote) quote = null; continue; }
    if (character === '"' || character === "'") { quote = character; continue; }
    if (character !== '=') continue;
    const keys = splitTomlDottedKey(line.slice(0, index));
    return keys && keys.length ? { keys, value: stripTomlComment(line.slice(index + 1)) } : null;
  }
  return null;
}

function tomlStringArray(raw) {
  const text = stripTomlComment(raw);
  if (!text.startsWith('[') || !text.endsWith(']')) return null;
  const result = [];
  let index = 1;
  while (index < text.length - 1) {
    while (/[\s,]/.test(text[index] || '')) index += 1;
    if (index >= text.length - 1) break;
    const rest = text.slice(index);
    const value = tomlString(rest);
    if (value === null) return null;
    result.push(value);
    if (rest[0] === '"') {
      const token = rest.match(/^"(?:\\.|[^"\\])*"/);
      if (!token) return null;
      index += token[0].length;
    } else {
      const end = rest.indexOf("'", 1);
      if (end < 0) return null;
      index += end + 1;
    }
    while (/\s/.test(text[index] || '')) index += 1;
    if (text[index] !== ',' && index < text.length - 1) return null;
  }
  return result;
}

function tomlBalancedEnd(source, start, open, close) {
  let depth = 0;
  let quote = null;
  let escaped = false;
  let comment = false;
  for (let index = start; index < source.length; index += 1) {
    const character = source[index];
    if (comment) { if (character === '\n') comment = false; continue; }
    if (escaped) { escaped = false; continue; }
    if (quote === '"' && character === '\\') { escaped = true; continue; }
    if (quote) { if (character === quote) quote = null; continue; }
    if (character === '#') { comment = true; continue; }
    if (character === '"' || character === "'") { quote = character; continue; }
    if (character === open) depth += 1;
    else if (character === close && --depth === 0) return index;
  }
  return -1;
}

function splitTomlTopLevel(source) {
  const parts = [];
  let start = 0;
  let square = 0;
  let curly = 0;
  let quote = null;
  let escaped = false;
  for (let index = 0; index <= source.length; index += 1) {
    const character = source[index];
    if (escaped) { escaped = false; continue; }
    if (quote === '"' && character === '\\') { escaped = true; continue; }
    if (quote) { if (character === quote) quote = null; continue; }
    if (character === '"' || character === "'") { quote = character; continue; }
    if (character === '[') square += 1;
    else if (character === ']') square -= 1;
    else if (character === '{') curly += 1;
    else if (character === '}') curly -= 1;
    if ((character === ',' && square === 0 && curly === 0) || index === source.length) {
      parts.push(source.slice(start, index));
      start = index + 1;
    }
  }
  return parts;
}

function codexSystemConfigFile() {
  if (process.env.CLAUDEX_CODEX_SYSTEM_CONFIG_FILE) return path.resolve(expandHome(process.env.CLAUDEX_CODEX_SYSTEM_CONFIG_FILE));
  return isWindows
    ? path.join(process.env.ProgramData || 'C:\\ProgramData', 'Codex', 'config.toml')
    : '/etc/codex/config.toml';
}

function codexProjectTrusted(repoRoot) {
  const forced = String(process.env.CLAUDEX_CODEX_PROJECT_TRUST || '').toLowerCase();
  if (forced === 'trusted') return true;
  if (forced === 'untrusted') return false;
  let trusted = true;
  for (const file of [codexSystemConfigFile(), path.join(codexHome, 'config.toml')]) {
    let source;
    try { source = fs.readFileSync(file, 'utf8'); } catch { continue; }
    let table = null;
    for (const line of source.split(/\r?\n/)) {
      const header = line.match(/^\s*\[\s*([^\]]+)\s*\]\s*(?:#.*)?$/);
      if (header) { table = splitTomlDottedKey(header[1]); continue; }
      if (!table || table.length !== 2 || table[0] !== 'projects') continue;
      let configured;
      try { configured = canonical(path.resolve(expandHome(table[1]))); } catch { continue; }
      if (configured !== canonical(repoRoot)) continue;
      const assignment = tomlAssignment(line);
      if (!assignment || assignment.keys.length !== 1 || assignment.keys[0] !== 'trust_level') continue;
      const level = tomlString(assignment.value);
      if (level === 'trusted') trusted = true;
      if (level === 'untrusted') trusted = false;
    }
  }
  return trusted;
}

function codexConfigFiles(projectDir, repoRoot, projectTrusted = codexProjectTrusted(repoRoot)) {
  const files = [codexSystemConfigFile(), path.join(codexHome, 'config.toml')];
  if (projectTrusted && projectDir && repoRoot) {
    for (const directory of ancestry(projectDir, repoRoot).reverse()) files.push(path.join(directory, '.codex', 'config.toml'));
  }
  return files;
}

function effectiveCodexProjectConfig(projectDir, repoRoot, globalOnly = false) {
  const projectTrusted = globalOnly ? false : codexProjectTrusted(repoRoot);
  let projectDocMaxBytes = DEFAULT_MAX_INSTRUCTION_BYTES;
  let fallbackFilenames = [];
  for (const file of codexConfigFiles(projectDir, repoRoot, projectTrusted)) {
    let source;
    try { source = fs.readFileSync(file, 'utf8'); } catch { continue; }
    let inTopLevel = true;
    const lines = source.split(/\r?\n/);
    for (let index = 0; index < lines.length; index += 1) {
      const line = lines[index];
      if (/^\s*\[/.test(line)) { inTopLevel = false; continue; }
      if (!inTopLevel) continue;
      const assignment = tomlAssignment(line);
      if (!assignment || assignment.keys.length !== 1) continue;
      if (assignment.keys[0] === 'project_doc_max_bytes' && /^\d+$/.test(assignment.value)) {
        projectDocMaxBytes = Math.min(MAX_TREE_BYTES, Number(assignment.value));
      } else if (assignment.keys[0] === 'project_doc_fallback_filenames') {
        let rawValue = assignment.value;
        if (rawValue.trimStart().startsWith('[') && tomlBalancedEnd(rawValue, rawValue.indexOf('['), '[', ']') < 0) {
          while (++index < lines.length) {
            rawValue += `\n${lines[index]}`;
            if (tomlBalancedEnd(rawValue, rawValue.indexOf('['), '[', ']') >= 0) break;
          }
        }
        const parsed = tomlStringArray(rawValue);
        if (parsed) fallbackFilenames = [...new Set(parsed.filter((name) => typeof name === 'string' && name && path.basename(name) === name))];
      }
    }
  }
  return { projectTrusted, projectDocMaxBytes, fallbackFilenames };
}

function parseDisabledCodexSkills(projectDir, repoRoot, projectTrusted = codexProjectTrusted(repoRoot)) {
  const states = new Map();
  for (const file of codexConfigFiles(projectDir, repoRoot, projectTrusted)) {
    let source = '';
    try { source = fs.readFileSync(file, 'utf8'); } catch { continue; }
    const baseDirectory = path.dirname(file);
    const events = [];
    const readConfig = (body) => {
      const config = {};
      for (const line of body.split(/\r?\n/)) {
        const assignment = tomlAssignment(line);
        if (!assignment || assignment.keys.length !== 1) continue;
        if (assignment.keys[0] === 'path') config.path = tomlString(assignment.value);
        if (assignment.keys[0] === 'enabled' && /^(?:true|false)$/i.test(assignment.value)) {
          config.enabled = assignment.value.toLowerCase() === 'true';
        }
      }
      return config;
    };
    const arrayTablePattern = /^\s*\[\[\s*([^\]]+)\s*\]\]\s*(?:#.*)?$/gm;
    for (const header of source.matchAll(arrayTablePattern)) {
      const keys = splitTomlDottedKey(header[1]);
      if (!keys || keys.length !== 2 || keys[0] !== 'skills' || keys[1] !== 'config') continue;
      const bodyStart = header.index + header[0].length;
      const nextHeader = source.slice(bodyStart).search(/^\s*\[/m);
      const bodyEnd = nextHeader < 0 ? source.length : bodyStart + nextHeader;
      events.push({ index: header.index, ...readConfig(source.slice(bodyStart, bodyEnd)) });
    }

    const inlinePattern = /(?:^|\n)\s*(?:"skills"|'skills'|skills)\s*\.\s*(?:"config"|'config'|config)\s*=\s*\[/gm;
    for (const inline of source.matchAll(inlinePattern)) {
      const open = inline.index + inline[0].lastIndexOf('[');
      const close = tomlBalancedEnd(source, open, '[', ']');
      if (close < 0) continue;
      const body = source.slice(open + 1, close);
      for (let cursor = 0; cursor < body.length;) {
        const relativeOpen = body.indexOf('{', cursor);
        if (relativeOpen < 0) break;
        const relativeClose = tomlBalancedEnd(body, relativeOpen, '{', '}');
        if (relativeClose < 0) break;
        const table = {};
        for (const piece of splitTomlTopLevel(body.slice(relativeOpen + 1, relativeClose))) {
          const assignment = tomlAssignment(piece);
          if (!assignment || assignment.keys.length !== 1) continue;
          if (assignment.keys[0] === 'path') table.path = tomlString(assignment.value);
          if (assignment.keys[0] === 'enabled' && /^(?:true|false)$/i.test(assignment.value)) {
            table.enabled = assignment.value.toLowerCase() === 'true';
          }
        }
        events.push({ index: open + 1 + relativeOpen, ...table });
        cursor = relativeClose + 1;
      }
    }

    for (const event of events.sort((left, right) => left.index - right.index)) {
      if (!event.path || typeof event.enabled !== 'boolean') continue;
      const configured = path.isAbsolute(event.path) ? event.path : path.resolve(baseDirectory, event.path);
      states.set(canonical(/SKILL\.md$/i.test(configured) ? path.dirname(configured) : configured), event.enabled);
    }
  }
  return new Set([...states].filter(([, enabled]) => !enabled).map(([configured]) => configured));
}

function codexPolicyDisablesImplicit(skillRoot) {
  let source = '';
  try { source = fs.readFileSync(path.join(skillRoot, 'agents', 'openai.yaml'), 'utf8'); } catch { return false; }
  const lines = source.split(/\r?\n/);
  let policyIndent = -1;
  for (const line of lines) {
    if (/^\s*(?:#.*)?$/.test(line)) continue;
    const entry = yamlMappingEntry(line);
    if (!entry) continue;
    if (entry.indent === 0 && entry.key === 'policy') {
      policyIndent = entry.indent;
      const flow = entry.value.trim();
      if (flow.startsWith('{') && flow.endsWith('}')) {
        for (const piece of flow.slice(1, -1).split(',')) {
          const item = yamlMappingEntry(piece.trim());
          if (item && item.key === 'allow_implicit_invocation' && /^false(?:\s+#.*)?$/i.test(item.value.trim())) return true;
        }
      }
      continue;
    }
    if (policyIndent >= 0 && entry.indent <= policyIndent) policyIndent = -1;
    if (policyIndent >= 0 && entry.key === 'allow_implicit_invocation' && /^false(?:\s+#.*)?$/i.test(entry.value.trim())) return true;
  }
  return false;
}

function remapClaudeModel(markdown) {
  const parsed = frontmatter(markdown);
  if (!parsed) return { markdown, changed: false, mappings: [] };
  const mappings = [];
  const replaced = parsed.body.split(/\r?\n/).map((line) => {
    const entry = yamlMappingEntry(line);
    if (!entry || entry.indent !== 0 || entry.key.toLocaleLowerCase() !== 'model') return line;
    const scalar = entry.value.match(/^(\s*)(["']?)([^\s#"']+)\2(\s*(?:#.*)?)$/);
    if (!scalar) return line;
    const [, whitespace, quote, model, suffix] = scalar;
    const normalized = model.toLocaleLowerCase().replace(/\[1m\]$/, '');
    if (!/(?:opus|sonnet|haiku|fable|best)/.test(normalized)) return line;
    const family = /(?:opus|fable|best)/.test(normalized) ? 'gpt-5.6-sol' : /haiku/.test(normalized) ? 'gpt-5.6-luna' : 'gpt-5.6-terra';
    mappings.push({ from: model, to: family });
    const valueStart = line.length - entry.value.length;
    return `${line.slice(0, valueStart)}${whitespace}${quote}${family}${quote}${suffix}`;
  }).join(parsed.eol);
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
  const directSkillRoot = existsFile(path.join(root, 'SKILL.md'));
  if (directSkillRoot) entries = [{ name: path.basename(root), root }];
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
    if (metadata.pluginRootBoundary && !isWithin(realRoot, metadata.pluginRootBoundary)) {
      warnings.push(`Ignored plugin skill symlink outside its plugin: ${entry.root}`);
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
    } else if (metadata.pluginRootBoundary && directSkillRoot) {
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
      scanBoundary: metadata.pluginRootBoundary || metadata.projectBoundary || null,
    });
  }
}

function discoverClaudeCommands(root, candidates, warnings, metadata = {}) {
  const boundary = metadata.pluginRootBoundary || metadata.commandBoundary || (existsDirectory(root) ? root : path.dirname(root));
  if (!isWithin(root, boundary)) {
    warnings.push(`Ignored Claude command path outside its command boundary: ${root}`);
    return;
  }
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
  const realRoot = canonical(root);
  const visited = metadata.commandVisited || new Set();
  if (visited.has(realRoot)) {
    warnings.push(`Ignored recursive Claude command directory cycle: ${root}`);
    return;
  }
  visited.add(realRoot);
  const recursiveMetadata = { ...metadata, commandBoundary: boundary, commandVisited: visited };
  if (existsFile(path.join(root, 'SKILL.md'))) {
    discoverSkillRoot(root, {
      ...recursiveMetadata, provider: 'claude', kind: metadata.kind || 'claude-command',
      sourceTag: metadata.sourceTag || 'claude-command', priority: metadata.priority || 20,
    }, candidates, new Set(), warnings);
    return;
  }
  let entries;
  try { entries = fs.readdirSync(root, { withFileTypes: true }); }
  catch (error) { warnings.push(`Could not read Claude command directory ${root}: ${error.message}`); return; }
  for (const entry of entries) {
    const entryPath = path.join(root, entry.name);
    if (entry.isDirectory() || (entry.isSymbolicLink() && existsDirectory(entryPath))) {
      if (!isWithin(entryPath, boundary)) {
        warnings.push(`Ignored Claude command symlink outside its command boundary: ${entryPath}`);
        continue;
      }
      discoverClaudeCommands(entryPath, candidates, warnings, recursiveMetadata);
      continue;
    }
    if ((!entry.isFile() && !(entry.isSymbolicLink() && existsFile(entryPath))) || !/\.md$/i.test(entry.name)) continue;
    if (!isWithin(entryPath, boundary)) {
      warnings.push(`Ignored Claude command symlink outside its command boundary: ${entryPath}`);
      continue;
    }
    const commandName = entry.name.replace(/\.md$/i, '');
    const skillOverride = overrideState(metadata.skillOverrides && metadata.skillOverrides[commandName]);
    if (skillOverride === 'off') continue;
    const commandFile = entryPath;
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

function claudeManagedSkillsRoot() {
  if (process.env.CLAUDEX_CLAUDE_MANAGED_SKILLS_DIR) return path.resolve(expandHome(process.env.CLAUDEX_CLAUDE_MANAGED_SKILLS_DIR));
  return isWindows
    ? path.join(process.env.ProgramData || 'C:\\ProgramData', 'ClaudeCode', 'skills')
    : process.platform === 'darwin'
      ? '/Library/Application Support/ClaudeCode/skills'
      : '/etc/claude-code/skills';
}

function discoverNativeReservedNames() {
  const names = new Set();
  discoverNativeNamesAt(configDir, names);
  discoverNativeNamesAt(path.dirname(claudeManagedSkillsRoot()), names);
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

function mergedClaudeSettings(projectDir, repoRoot, globalOnly = false) {
  const settings = { enabledPlugins: {}, skillOverrides: {}, disableSideloadFlags: false, strictPluginOnlyCustomization: false };
  const apply = (file) => {
    const value = readJson(file, {});
    if (value && typeof value.enabledPlugins === 'object' && value.enabledPlugins) Object.assign(settings.enabledPlugins, value.enabledPlugins);
    if (value && typeof value.skillOverrides === 'object' && value.skillOverrides) Object.assign(settings.skillOverrides, value.skillOverrides);
    if (typeof value.disableSideloadFlags === 'boolean') settings.disableSideloadFlags = value.disableSideloadFlags;
    if (typeof value.strictPluginOnlyCustomization === 'boolean'
        || (Array.isArray(value.strictPluginOnlyCustomization)
          && value.strictPluginOnlyCustomization.every((entry) => typeof entry === 'string'))) {
      settings.strictPluginOnlyCustomization = value.strictPluginOnlyCustomization;
    }
  };
  apply(path.join(claudeHome, 'settings.json'));
  if (!globalOnly) {
    apply(path.join(repoRoot, '.claude', 'settings.json'));
    // Claude still reads legacy nested local settings, but the repository-root
    // local file is authoritative when both forms exist.
    for (const directory of ancestry(projectDir, repoRoot).slice(0, -1).reverse()) {
      apply(path.join(directory, '.claude', 'settings.local.json'));
    }
    apply(path.join(repoRoot, '.claude', 'settings.local.json'));
  }
  const managed = process.env.CLAUDEX_CLAUDE_MANAGED_SETTINGS_FILE || (isWindows
    ? path.join(process.env.SystemDrive || 'C:', 'Program Files', 'ClaudeCode', 'managed-settings.json')
    : process.platform === 'darwin'
      ? '/Library/Application Support/ClaudeCode/managed-settings.json'
      : '/etc/claude-code/managed-settings.json');
  apply(managed);
  for (const dropInDirectory of [...new Set([
    path.join(path.dirname(managed), 'managed-settings.d'),
    `${managed}.d`,
  ])]) {
    if (!existsDirectory(dropInDirectory)) continue;
    let files = [];
    try { files = fs.readdirSync(dropInDirectory).filter((name) => /\.json$/i.test(name)).sort(); } catch { files = []; }
    for (const name of files) apply(path.join(dropInDirectory, name));
  }
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
    ? (existsFile(claude) ? claude : existsFile(codex) ? codex : null)
    : (existsFile(codex) ? codex : existsFile(claude) ? claude : null);
  if (!file) {
    return provider === 'claude'
      ? { file: null, value: {}, valid: true, present: false, error: null }
      : { file: null, value: {}, valid: false, present: false, error: 'required plugin manifest is missing' };
  }
  try {
    const value = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('manifest root must be an object');
    if (typeof value.name !== 'string' || !/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(value.name)) {
      throw new Error('manifest name is required and must use lowercase words separated by hyphens');
    }
    for (const field of ['skills', 'commands']) {
      if (value[field] !== undefined && typeof value[field] !== 'string'
          && !(Array.isArray(value[field]) && value[field].every((entry) => typeof entry === 'string'))) {
        throw new Error(`manifest ${field} must be a string or array of strings`);
      }
    }
    if (value.defaultEnabled !== undefined && typeof value.defaultEnabled !== 'boolean') {
      throw new Error('manifest defaultEnabled must be a boolean');
    }
    return { file, value, valid: true, present: true, error: null };
  } catch (error) {
    return { file, value: {}, valid: false, present: true, error: error.message };
  }
}

function pluginSkillRoots(pluginRoot, provider, warnings, inspected = pluginManifest(pluginRoot, provider)) {
  const { file: manifestFile, value: manifest } = inspected;
  let configured = manifest && manifest.skills;
  if (typeof configured === 'string') configured = [configured];
  if (!Array.isArray(configured)) configured = [];
  const claudeManifest = !/\.codex-plugin[\\/]plugin\.json$/i.test(manifestFile || '');
  const hasConfiguredSkills = Object.prototype.hasOwnProperty.call(manifest || {}, 'skills');
  if (claudeManifest) configured = ['./skills', ...configured];
  else if (!claudeManifest && configured.length === 0) configured = ['skills'];
  configured = [...new Set(configured)];
  const roots = [];
  for (const relative of configured) {
    if (typeof relative !== 'string' || path.isAbsolute(relative)) continue;
    if (claudeManifest && !relative.startsWith('./')) {
      warnings.push(`Ignored Claude plugin skill path that must start with ./: ${relative}`);
      continue;
    }
    const candidate = path.resolve(pluginRoot, relative);
    if (!isWithin(candidate, pluginRoot)) {
      warnings.push(`Ignored plugin skill path outside its plugin: ${relative}`);
      continue;
    }
    if (existsDirectory(candidate)) roots.push(candidate);
  }
  if (claudeManifest && !hasConfiguredSkills && !existsDirectory(path.join(pluginRoot, 'skills'))
      && existsFile(path.join(pluginRoot, 'SKILL.md'))) roots.unshift(pluginRoot);
  return roots;
}

function discoverPluginContents(pluginRoot, metadata, candidates, disabled, warnings) {
  const inspected = pluginManifest(pluginRoot, metadata.provider);
  const { file: manifestFile, value: manifest } = inspected;
  if (!inspected.valid) {
    warnings.push(`Ignored malformed plugin manifest ${manifestFile || pluginRoot}: ${inspected.error}`);
    return;
  }
  const namespace = skillAlias((manifest && manifest.name) || metadata.pluginName || path.basename(pluginRoot), 'plugin');
  for (const root of pluginSkillRoots(pluginRoot, metadata.provider, warnings, inspected)) {
    discoverSkillRoot(root, { ...metadata, namespace, pluginName: namespace, pluginRootBoundary: pluginRoot }, candidates, disabled, warnings);
  }
  if (!/\.codex-plugin[\\/]plugin\.json$/i.test(manifestFile || '')) {
    let commandRoots = manifest && manifest.commands;
    if (typeof commandRoots === 'string') commandRoots = [commandRoots];
    if (!Array.isArray(commandRoots)) commandRoots = ['./commands'];
    for (const relative of commandRoots) {
      if (typeof relative !== 'string' || path.isAbsolute(relative)) continue;
      if (!relative.startsWith('./')) {
        warnings.push(`Ignored Claude plugin command path that must start with ./: ${relative}`);
        continue;
      }
      const commandRoot = path.resolve(pluginRoot, relative);
      if (isWithin(commandRoot, pluginRoot)) discoverClaudeCommands(commandRoot, candidates, warnings, {
        ...metadata, namespace, pluginRootBoundary: pluginRoot,
      });
    }
  }
}

function discoverClaudePlugins(projectDir, repoRoot, candidates, disabled, warnings, globalOnly = false, settings = null) {
  if (!pluginEnabled) return;
  const registry = readJson(path.join(claudeHome, 'plugins', 'installed_plugins.json'), {});
  const enabled = (settings || mergedClaudeSettings(projectDir, repoRoot, globalOnly)).enabledPlugins;
  const plugins = registry && typeof registry.plugins === 'object' && registry.plugins ? registry.plugins : {};
  for (const [pluginId, installs] of Object.entries(plugins)) {
    if (!Array.isArray(installs)) continue;
    for (const install of installs) {
      if (!install || typeof install !== 'object') { warnings.push(`Ignored malformed Claude plugin record for ${pluginId}`); continue; }
      const scope = String(install.scope || 'user');
      if (scope !== 'user' && scope !== 'managed') {
        if (globalOnly) continue;
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

function insideGitWorktree(candidate) {
  let cursor = path.resolve(candidate);
  while (true) {
    if (fs.existsSync(path.join(cursor, '.git'))) return true;
    const parent = path.dirname(cursor);
    if (parent === cursor) return false;
    cursor = parent;
  }
}

function neutralPluginInventoryCwd() {
  for (const candidate of [os.tmpdir(), home, path.parse(configDir).root]) {
    try {
      const resolved = canonical(candidate);
      if (existsDirectory(resolved) && !insideGitWorktree(resolved)) return resolved;
    } catch { }
  }
  return null;
}

function codexPluginInventory(warnings, globalOnly = false) {
  if (!pluginEnabled) return [];
  if (process.env.CLAUDEX_TEST_CODEX_PLUGIN_LIST_FILE) {
    const fixture = readJson(process.env.CLAUDEX_TEST_CODEX_PLUGIN_LIST_FILE, {});
    const list = Array.isArray(fixture) ? fixture : fixture && fixture.installed;
    return Array.isArray(list) ? list : [];
  }
  let result;
  try {
    const neutralCwd = globalOnly ? neutralPluginInventoryCwd() : null;
    if (globalOnly && !neutralCwd) {
      warnings.push('Could not inspect global Codex plugins from a neutral directory; standalone Codex skills are still available.');
      return [];
    }
    result = childProcess.spawnSync('codex', ['plugin', 'list', '--json'], {
      encoding: 'utf8', timeout: 5000, maxBuffer: 16 * 1024 * 1024,
      windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'], cwd: neutralCwd || undefined,
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

function discoverCodexPlugins(candidates, disabled, warnings, globalOnly = false) {
  const inventory = codexPluginInventory(warnings, globalOnly);
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
  const matches = (suffix) => normalized === suffix || normalized.endsWith(`/${suffix}`);
  if (base === '.env' || (/^\.env\./.test(base) && !/\.(?:example|sample|template)$/.test(base))) return true;
  if (['.npmrc', '.pypirc', '.netrc', '.git-credentials', '.credentials.json', 'credentials',
    'credentials.json', 'auth.json', 'id_rsa', 'id_ed25519'].includes(base)) return true;
  return matches('.aws/credentials')
    || matches('.config/gcloud/application_default_credentials.json')
    || matches('.config/gh/hosts.yml')
    || matches('.config/glab-cli/config.yml')
    || matches('.docker/config.json')
    || matches('.kube/config');
}

function sensitiveContent(buffer) {
  return /-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----/.test(buffer.toString('utf8'));
}

function scanTree(sourceRoot, excludePluginRuntime = false, allowedBoundary = sourceRoot) {
  const root = canonical(sourceRoot);
  const boundary = canonical(allowedBoundary || sourceRoot);
  const boundaryLabel = root === boundary ? 'root' : 'trust boundary';
  if (!existsDirectory(root)) throw new Error(`skill source is not a directory: ${sourceRoot}`);
  if (!isWithin(root, boundary)) throw new Error(`skill source is outside its trust boundary: ${sourceRoot}`);
  const files = [];
  let totalBytes = 0;
  const activeDirectories = new Set();

  const walk = (physicalDirectory, logicalPrefix, depth) => {
    if (depth > MAX_DEPTH) throw new Error(`skill tree exceeds ${MAX_DEPTH} levels`);
    const realDirectory = canonical(physicalDirectory);
    if (!isWithin(realDirectory, boundary)) throw new Error(`skill support path escapes its ${boundaryLabel}: ${logicalPrefix || '.'}`);
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
        if (!isWithin(resolved, boundary)) throw new Error(`skill support symlink escapes its ${boundaryLabel}: ${logical}`);
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
      if (fingerprint.sensitive) throw new Error(`skill tree contains material that resembles a private key: ${logical}`);
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
      } else candidate.tree = scanTree(candidate.source, candidate.excludePluginRuntime, candidate.scanBoundary || candidate.source);
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

function verifiedInstructionBytes(file) {
  const bytes = fs.readFileSync(file.realSource);
  const digest = crypto.createHash('sha256').update(bytes).digest('hex');
  if (bytes.length !== file.size || digest !== file.digest) {
    throw new SourceChangedError(`Codex instructions changed while staging: ${file.source}`);
  }
  return Buffer.from(bytes.toString('utf8').trim(), 'utf8');
}

function utf8Prefix(buffer, limit) {
  if (buffer.length <= limit) return buffer;
  let text = buffer.subarray(0, Math.max(0, limit)).toString('utf8');
  if (text.endsWith('\uFFFD')) text = text.slice(0, -1);
  return Buffer.from(text, 'utf8');
}

function materializeInstructions(instructions, stage) {
  const chunks = [];
  const records = [];
  let written = 0;
  for (const file of instructions.files) {
    const bytes = verifiedInstructionBytes(file);
    const separator = written > 0 && file.includedBytes > 0 ? Buffer.from('\n\n') : Buffer.alloc(0);
    const content = utf8Prefix(bytes, file.includedBytes);
    if (content.length > 0) {
      chunks.push(separator, content);
      written += separator.length + content.length;
    }
    records.push({
      scope: file.scope, source: file.source, name: file.name,
      includedBytes: content.length, truncated: content.length < bytes.length,
    });
  }
  if (written > 0) writeExclusive(path.join(stage, 'CLAUDE.md'), Buffer.concat(chunks), 0o600);
  return records;
}

function currentInstructionSignature(instructions) {
  if (instructions.signature === 'off') return 'off';
  const files = instructions.files.map((file) => {
    const bytes = fs.readFileSync(file.realSource);
    if (bytes.length !== file.size) throw new SourceChangedError(`Codex instructions changed while publishing: ${file.source}`);
    return {
      scope: file.scope, source: file.realSource, size: bytes.length,
      digest: crypto.createHash('sha256').update(bytes).digest('hex'),
      renderedSize: Buffer.byteLength(bytes.toString('utf8').trim(), 'utf8'), includedBytes: file.includedBytes,
    };
  });
  return crypto.createHash('sha256').update(JSON.stringify({
    files, maxBytes: instructions.maxBytes, fallbackFilenames: instructions.fallbackFilenames,
    projectTrusted: instructions.projectTrusted,
  })).digest('hex');
}

function sourceSignature(mapping) {
  return {
    alias: mapping.alias, namespace: mapping.namespace || null,
    source: mapping.candidate.realSource, kind: mapping.candidate.kind,
    tree: mapping.candidate.tree.signature, manualOnly: mapping.candidate.manualOnly,
    overrideState: mapping.candidate.overrideState || 'on',
  };
}

function discover(projectDir, scopeMode = SCOPE_PROJECT) {
  const globalOnly = scopeMode === SCOPE_GLOBAL_ONLY;
  const warnings = [];
  const candidates = [];
  const repoRoot = globalOnly ? null : findRepoRoot(projectDir);
  const codexConfig = effectiveCodexProjectConfig(projectDir, repoRoot, globalOnly);
  const instructions = discoverInstructions(projectDir, repoRoot, warnings, codexConfig, globalOnly);
  const directories = globalOnly ? [] : ancestry(projectDir, repoRoot);
  const disabled = parseDisabledCodexSkills(projectDir, repoRoot, codexConfig.projectTrusted);
  const claudeSettings = mergedClaudeSettings(projectDir, repoRoot, globalOnly);
  const nativeNames = discoverNativeReservedNames();
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
  // Codex ships its built-in skills below CODEX_HOME/skills/.system rather
  // than directly below the ordinary user skill root. They are visible in
  // Codex's skill picker and must therefore be visible in Claudex too. Keep
  // them lower precedence than user/admin sources so a user-installed skill
  // with the same identity retains the short alias.
  discoverSkillRoot(path.join(codexHome, 'skills', '.system'), {
    provider: 'codex', kind: 'codex-system', sourceTag: 'codex-system', priority: 90,
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

  discoverClaudePlugins(projectDir, repoRoot, candidates, disabled, warnings, globalOnly, claudeSettings);
  discoverCodexPlugins(candidates, disabled, warnings, globalOnly);
  const unique = uniqueCandidates(prepareCandidates(candidates, warnings));
  const allowPluginDirs = !claudeSettings.disableSideloadFlags;
  const strictSkills = claudeSettings.strictPluginOnlyCustomization === true
    || (Array.isArray(claudeSettings.strictPluginOnlyCustomization)
      && claudeSettings.strictPluginOnlyCustomization.some((entry) => entry.toLocaleLowerCase() === 'skills'));
  const strictCommands = claudeSettings.strictPluginOnlyCustomization === true
    || (Array.isArray(claudeSettings.strictPluginOnlyCustomization)
      && claudeSettings.strictPluginOnlyCustomization.some((entry) => entry.toLocaleLowerCase() === 'commands'));
  if (!allowPluginDirs) warnings.push(
    'Managed Claude settings disable --plugin-dir sideloading; imported skills from plugins and $skill reference hooks were omitted. Ask an administrator to install or allow those plugins.',
  );
  if (strictSkills) warnings.push(
    'Managed Claude settings require skills to come from plugins; standalone imported skills were omitted while plugin skills remain available.',
  );
  if (strictCommands && !strictSkills) warnings.push(
    'Managed Claude settings require commands to come from plugins; standalone imported commands were omitted while unrelated skills remain available.',
  );
  const standalone = unique.filter((candidate) => candidate.kind === 'claude-command' ? !strictCommands : !strictSkills);
  return {
    mappings: assignAliases(standalone, nativeNames),
    pluginMappings: allowPluginDirs ? assignPluginAliases(unique, nativePluginNames) : [],
    instructions,
    warnings,
    repoRoot,
    scopeMode,
    allowPluginDirs,
    strictSkills,
    strictCommands,
  };
}

function promptHookSource() {
  return `'use strict';
const fs = require('fs');
const path = require('path');
const MAX_INPUT = 1048576;
// Claude Code currently injects at most 10,000 characters of hook context
// directly. Stay below that boundary in UTF-8 bytes so referenced skill
// instructions do not unexpectedly become an out-of-band attachment.
const MAX_CONTEXT = 10000;
const MAX_SKILL = 8192;
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
      const ecosystem = item.provider === 'claude' ? 'Claude Code' : item.provider === 'codex' ? 'Codex' : 'shared';
      const block = '\\nThe user explicitly referenced the installed ' + ecosystem + ' skill $' + name + '. Apply these instructions. Skill directory: ' + item.directory + '\\n<claudex-skill name="' + name + '" provider="' + item.provider + '">\\n' + markdown + '\\n</claudex-skill>\\n';
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

function materializeDollarReferencePlugin(stage, references, allowPluginDirs = true) {
  if (!allowPluginDirs || !dollarReferencesEnabled || references.length === 0) return null;
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
    skills: manifest.skills || [], instructions: manifest.instructions || [], modelMappings: manifest.modelMappings || [],
    warnings: boundedWarnings([...currentWarnings, ...extraWarnings]),
  };
}

function publishedContentInventory(root) {
  const files = [];
  let total = 0;
  const walk = (directory, prefix = '') => {
    let entries = fs.readdirSync(directory, { withFileTypes: true });
    entries = entries.sort((left, right) => left.name.localeCompare(right.name));
    for (const entry of entries) {
      const relative = prefix ? `${prefix}/${entry.name}` : entry.name;
      if (relative === 'manifest.json') continue;
      const candidate = path.join(directory, entry.name);
      const stat = fs.lstatSync(candidate);
      if (stat.isSymbolicLink()) throw new Error(`published cache contains a symlink: ${relative}`);
      if (stat.isDirectory()) { walk(candidate, relative); continue; }
      if (!stat.isFile() || stat.size > MAX_FILE_BYTES || files.length >= MAX_FILES) throw new Error('published cache exceeds safety limits');
      total += stat.size;
      if (total > MAX_TREE_BYTES) throw new Error('published cache exceeds safety limits');
      const bytes = fs.readFileSync(candidate);
      files.push({ relative, size: bytes.length, digest: crypto.createHash('sha256').update(bytes).digest('hex') });
    }
  };
  walk(root);
  return files;
}

function contentIntegrity(files) {
  return crypto.createHash('sha256').update(JSON.stringify(files)).digest('hex');
}

function validManifest(file, expectedPolicyFingerprint = null) {
  const manifest = readJson(file, null);
  if (!manifest || manifest.schema !== BRIDGE_SCHEMA || manifest.format !== BRIDGE_FORMAT
      || !Array.isArray(manifest.skills) || !Array.isArray(manifest.instructions)
      || !Array.isArray(manifest.pluginRelativeDirs) || !Array.isArray(manifest.contentFiles)
      || typeof manifest.contentIntegrity !== 'string') return null;
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
  if (manifest.instructions.length > 0 && !existsFile(path.join(generation, 'CLAUDE.md'))) return null;
  for (const instruction of manifest.instructions) {
    if (!instruction || !['global', 'project'].includes(instruction.scope)
        || typeof instruction.source !== 'string' || !instruction.source
        || typeof instruction.includedBytes !== 'number' || instruction.includedBytes < 0) return null;
  }
  try {
    const inventory = publishedContentInventory(generation);
    if (contentIntegrity(inventory) !== manifest.contentIntegrity
        || JSON.stringify(inventory) !== JSON.stringify(manifest.contentFiles)) return null;
  } catch { return null; }
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

function bridgeCacheKey(projectDir, scopeMode) {
  return scopeMode === SCOPE_GLOBAL_ONLY ? SCOPE_GLOBAL_ONLY : `${SCOPE_PROJECT}:${canonical(projectDir)}`;
}

function syncOnce(projectDir, scopeMode = SCOPE_PROJECT) {
  const discovered = discover(projectDir, scopeMode);
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
  const policyInstructions = {
    files: discovered.instructions.files.map((file) => ({
      scope: file.scope, source: file.realSource, name: file.name,
    })),
    maxBytes: discovered.instructions.maxBytes,
    fallbackFilenames: discovered.instructions.fallbackFilenames,
    projectTrusted: discovered.instructions.projectTrusted,
  };
  const policyFingerprint = crypto.createHash('sha256').update(JSON.stringify({
    format: BRIDGE_FORMAT, pluginEnabled, dollarReferencesEnabled, instructionBridgeEnabled,
    scopeMode,
    allowPluginDirs: discovered.allowPluginDirs, strictSkills: discovered.strictSkills,
    strictCommands: discovered.strictCommands,
    skills: policySkills, instructions: policyInstructions,
  })).digest('hex');
  const fingerprint = crypto.createHash('sha256').update(JSON.stringify({
    schema: BRIDGE_SCHEMA, format: BRIDGE_FORMAT, platform: process.platform,
    scopeMode,
    signatures, instructionSignature: discovered.instructions.signature,
    dollarReferencesEnabled, instructionBridgeEnabled, policyFingerprint,
  })).digest('hex').slice(0, 20);
  const projectHash = crypto.createHash('sha256').update(bridgeCacheKey(projectDir, scopeMode)).digest('hex').slice(0, 12);
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
    const instructionRecords = materializeInstructions(discovered.instructions, stage);
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
        provider: mapping.candidate.provider,
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
          provider: mapping.candidate.provider,
        }]);
      }
      pluginRelativeDirs.push(relative.split(path.sep).join('/'));
    }

    const hookPlugin = materializeDollarReferencePlugin(stage, dollarReferences, discovered.allowPluginDirs);
    if (hookPlugin) pluginRelativeDirs.push(hookPlugin.split(path.sep).join('/'));

    for (const mapping of allMappings) {
      const fresh = mapping.candidate.commandFile
        ? crypto.createHash('sha256').update(fs.readFileSync(mapping.candidate.commandFile)).digest('hex')
        : scanTree(mapping.candidate.source, mapping.candidate.excludePluginRuntime,
          mapping.candidate.scanBoundary || mapping.candidate.source).signature;
      if (fresh !== mapping.candidate.tree.signature) throw new SourceChangedError(`skill changed while publishing: ${mapping.candidate.source}`);
    }
    if (currentInstructionSignature(discovered.instructions) !== discovered.instructions.signature) {
      throw new SourceChangedError('Codex instructions changed while publishing');
    }

    const contentFiles = publishedContentInventory(stage);
    manifest = {
      schema: BRIDGE_SCHEMA, format: BRIDGE_FORMAT, scopeMode,
      project: scopeMode === SCOPE_GLOBAL_ONLY ? null : path.resolve(projectDir), repoRoot: discovered.repoRoot,
      fingerprint, policyFingerprint, publishedAt: Date.now(), skills: records, instructions: instructionRecords,
      pluginRelativeDirs, modelMappings, warnings: boundedWarnings(discovered.warnings), contentFiles,
      contentIntegrity: contentIntegrity(contentFiles),
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

function sync(projectDir, scopeMode = SCOPE_PROJECT) {
  if (!bridgeEnabled) return { schema: BRIDGE_SCHEMA, enabled: false, overlay: null, addDirs: [], pluginDirs: [], skills: [], instructions: [], warnings: [] };
  const projectHash = crypto.createHash('sha256').update(bridgeCacheKey(projectDir, scopeMode)).digest('hex').slice(0, 12);
  const generations = path.join(configDir, 'skill-bridge', 'generations');
  let lastError;
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const result = syncOnce(projectDir, scopeMode);
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
  process.stdout.write(`Claudex skills: ${result.skills.length} bridged aliases, ${result.pluginDirs.length} isolated compatibility plugins, ${(result.instructions || []).length} Codex instruction files\n`);
  for (const skill of result.skills) {
    const qualifier = skill.collisionAlias ? ' (collision alias)' : '';
    process.stdout.write(`/${skill.alias}\t${skill.kind}${qualifier}\t${skill.source}\n`);
  }
  for (const pluginDir of result.pluginDirs) process.stdout.write(`plugin\t${pluginDir}\n`);
  for (const instruction of result.instructions || []) {
    const qualifier = instruction.truncated ? ' (truncated)' : '';
    process.stdout.write(`instructions\t${instruction.scope}${qualifier}\t${instruction.source}\n`);
  }
  for (const mapping of result.modelMappings || []) process.stdout.write(`model\t${mapping.from} -> ${mapping.to}\t${mapping.source}\n`);
  for (const warning of result.warnings || []) process.stderr.write(`claudex skills: ${warning}\n`);
}

function parseArguments(argv) {
  const command = argv[0] || 'sync';
  let project = process.cwd();
  let scopeMode = SCOPE_PROJECT;
  for (let index = 1; index < argv.length; index++) {
    if (argv[index] === '--project' && argv[index + 1]) project = argv[++index];
    else if (argv[index] === '--global-only') scopeMode = SCOPE_GLOBAL_ONLY;
    else throw new Error(`unknown argument: ${argv[index]}`);
  }
  return { command, project: path.resolve(project), scopeMode };
}

function main() {
  const { command, project, scopeMode } = parseArguments(process.argv.slice(2));
  if (!['sync', 'list', 'doctor'].includes(command)) throw new Error(`unknown command: ${command}`);
  const result = sync(project, scopeMode);
  if (command === 'sync') process.stdout.write(`${JSON.stringify(result)}\n`);
  else printList(result);
}

if (require.main === module) {
  try { main(); }
  catch (error) {
    process.stderr.write(`claudex skill bridge: ${safeWarning(error.message)}\n`);
    process.exit(1);
  }
}

module.exports = {
  assignAliases, codexPolicyDisablesImplicit, codexSkillIdentity, discover, ensureManualOnly,
  findRepoRoot, frontmatter, neutralPluginInventoryCwd, parseDisabledCodexSkills, remapClaudeModel,
  safeName, scanTree, skillAlias, sync,
};
