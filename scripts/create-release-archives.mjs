#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';

const [, , stageArgument, tarArgument, zipArgument] = process.argv;
if (!stageArgument || !tarArgument || !zipArgument || process.argv.length !== 5) {
  console.error('Usage: create-release-archives.mjs <staged-root> <output.tar.gz> <output.zip>');
  process.exit(2);
}

const stage = path.resolve(stageArgument);
const tarOutput = path.resolve(tarArgument);
const zipOutput = path.resolve(zipArgument);
const rootName = path.basename(stage);
const fixedMtime = 946684800;
const maximumArchiveBytes = 1024 * 1024 * 1024;
const executablePaths = new Set([
  'bootstrap.sh',
  'claudex',
  'codex-session',
  'install.sh',
  'install.zsh',
  'self-update',
  'statusline',
  'usage-limit',
  'bin/claudex-package.mjs',
]);

if (!/^claudex-(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/.test(rootName)) {
  throw new Error(`staged release root has an invalid name: ${rootName}`);
}

function compareNames(left, right) {
  return left < right ? -1 : left > right ? 1 : 0;
}

function assertSafeRelativePath(relative) {
  if (!relative || relative.includes('\0') || relative.includes('\\') || relative.startsWith('/')) {
    throw new Error(`unsafe release path: ${relative}`);
  }
  const segments = relative.replace(/\/$/, '').split('/');
  if (segments.some((segment) => !segment || segment === '.' || segment === '..')) {
    throw new Error(`unsafe release path: ${relative}`);
  }
}

function normalizeText(buffer, relative) {
  const text = buffer.toString('utf8');
  if (text.includes('\0') || !Buffer.from(text, 'utf8').equals(buffer)) {
    throw new Error(`release payload is not valid UTF-8 text: ${relative}`);
  }
  const newline = relative.toLowerCase().endsWith('.cmd') ? '\r\n' : '\n';
  return Buffer.from(text.replace(/\r\n|\r|\n/g, newline), 'utf8');
}

function collectEntries() {
  const entries = [];
  let totalBytes = 0;

  function visit(absolute, relative) {
    const stat = fs.lstatSync(absolute);
    assertSafeRelativePath(relative);
    if (stat.isSymbolicLink() || (!stat.isDirectory() && !stat.isFile())) {
      throw new Error(`release staging tree contains an unsupported file type: ${relative}`);
    }
    if (stat.isDirectory()) {
      entries.push({ name: `${relative}/`, directory: true, mode: 0o755, data: Buffer.alloc(0) });
      const children = fs.readdirSync(absolute).sort(compareNames);
      for (const child of children) visit(path.join(absolute, child), `${relative}/${child}`);
      return;
    }

    const original = fs.readFileSync(absolute);
    // The explicit release allowlist is entirely source, configuration, and
    // documentation text. Canonicalize every staged file so normal Windows
    // core.autocrlf behavior cannot affect package hashes; .cmd is the sole
    // CRLF format and every other release file uses LF.
    const data = normalizeText(original, relative);
    if (!data.equals(original)) fs.writeFileSync(absolute, data);
    totalBytes += data.length;
    if (totalBytes > maximumArchiveBytes) throw new Error('release payload exceeds the 1 GiB safety limit');
    entries.push({
      name: relative,
      directory: false,
      mode: executablePaths.has(relative.slice(rootName.length + 1)) ? 0o755 : 0o644,
      data,
    });
  }

  visit(stage, rootName);
  entries.sort((left, right) => compareNames(left.name, right.name));
  return entries;
}

function writeString(target, offset, length, value) {
  const encoded = Buffer.from(value, 'utf8');
  if (encoded.length > length) throw new Error(`archive header value is too long: ${value}`);
  encoded.copy(target, offset);
}

function writeOctal(target, offset, length, value) {
  const encoded = value.toString(8).padStart(length - 1, '0');
  if (encoded.length !== length - 1) throw new Error(`archive numeric value is too large: ${value}`);
  writeString(target, offset, length, `${encoded}\0`);
}

function splitUstarPath(name) {
  if (Buffer.byteLength(name) <= 100) return { name, prefix: '' };
  for (let index = name.length - 1; index > 0; index -= 1) {
    if (name[index] !== '/') continue;
    const prefix = name.slice(0, index);
    const suffix = name.slice(index + 1);
    if (suffix && Buffer.byteLength(prefix) <= 155 && Buffer.byteLength(suffix) <= 100) {
      return { name: suffix, prefix };
    }
  }
  throw new Error(`release path cannot be represented safely in ustar: ${name}`);
}

function createTar(entries) {
  const chunks = [];
  for (const entry of entries) {
    const header = Buffer.alloc(512);
    const split = splitUstarPath(entry.name);
    writeString(header, 0, 100, split.name);
    writeOctal(header, 100, 8, entry.mode);
    writeOctal(header, 108, 8, 0);
    writeOctal(header, 116, 8, 0);
    writeOctal(header, 124, 12, entry.data.length);
    writeOctal(header, 136, 12, fixedMtime);
    header.fill(0x20, 148, 156);
    header[156] = entry.directory ? 0x35 : 0x30;
    writeString(header, 257, 6, 'ustar\0');
    writeString(header, 263, 2, '00');
    writeString(header, 265, 32, 'root');
    writeString(header, 297, 32, 'root');
    writeOctal(header, 329, 8, 0);
    writeOctal(header, 337, 8, 0);
    writeString(header, 345, 155, split.prefix);
    const checksum = header.reduce((sum, byte) => sum + byte, 0).toString(8).padStart(6, '0');
    writeString(header, 148, 8, `${checksum}\0 `);
    chunks.push(header, entry.data);
    const padding = (512 - (entry.data.length % 512)) % 512;
    if (padding) chunks.push(Buffer.alloc(padding));
  }
  chunks.push(Buffer.alloc(1024));
  return Buffer.concat(chunks);
}

const crcTable = Array.from({ length: 256 }, (_, value) => {
  let crc = value;
  for (let bit = 0; bit < 8; bit += 1) crc = (crc & 1) ? (0xedb88320 ^ (crc >>> 1)) : (crc >>> 1);
  return crc >>> 0;
});

function crc32(buffer) {
  let crc = 0xffffffff;
  for (const byte of buffer) crc = crcTable[(crc ^ byte) & 0xff] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

function createStoredDeflate(buffer) {
  const chunks = [];
  if (buffer.length === 0) return Buffer.from([1, 0, 0, 0xff, 0xff]);
  for (let offset = 0; offset < buffer.length; offset += 65535) {
    const data = buffer.subarray(offset, Math.min(offset + 65535, buffer.length));
    const header = Buffer.alloc(5);
    header[0] = offset + data.length === buffer.length ? 1 : 0;
    header.writeUInt16LE(data.length, 1);
    header.writeUInt16LE((~data.length) & 0xffff, 3);
    chunks.push(header, data);
  }
  return Buffer.concat(chunks);
}

function createGzip(buffer) {
  const header = Buffer.from([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff]);
  const trailer = Buffer.alloc(8);
  trailer.writeUInt32LE(crc32(buffer), 0);
  trailer.writeUInt32LE(buffer.length >>> 0, 4);
  return Buffer.concat([header, createStoredDeflate(buffer), trailer]);
}

function createZip(entries) {
  const localChunks = [];
  const centralChunks = [];
  let localOffset = 0;
  const dosDate = ((2000 - 1980) << 9) | (1 << 5) | 1;

  for (const entry of entries) {
    const name = Buffer.from(entry.name, 'utf8');
    if (name.length > 0xffff) throw new Error(`ZIP path is too long: ${entry.name}`);
    const crc = crc32(entry.data);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(0x0800, 6);
    local.writeUInt16LE(0, 8);
    local.writeUInt16LE(0, 10);
    local.writeUInt16LE(dosDate, 12);
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(entry.data.length, 18);
    local.writeUInt32LE(entry.data.length, 22);
    local.writeUInt16LE(name.length, 26);
    local.writeUInt16LE(0, 28);
    localChunks.push(local, name, entry.data);

    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(0x0314, 4);
    central.writeUInt16LE(20, 6);
    central.writeUInt16LE(0x0800, 8);
    central.writeUInt16LE(0, 10);
    central.writeUInt16LE(0, 12);
    central.writeUInt16LE(dosDate, 14);
    central.writeUInt32LE(crc, 16);
    central.writeUInt32LE(entry.data.length, 20);
    central.writeUInt32LE(entry.data.length, 24);
    central.writeUInt16LE(name.length, 28);
    central.writeUInt16LE(0, 30);
    central.writeUInt16LE(0, 32);
    central.writeUInt16LE(0, 34);
    central.writeUInt16LE(0, 36);
    const unixMode = (entry.directory ? 0o040000 : 0o100000) | entry.mode;
    central.writeUInt32LE(((unixMode << 16) | (entry.directory ? 0x10 : 0)) >>> 0, 38);
    central.writeUInt32LE(localOffset, 42);
    centralChunks.push(central, name);
    localOffset += local.length + name.length + entry.data.length;
  }

  if (entries.length > 0xffff) throw new Error('release ZIP has too many entries');
  const centralDirectory = Buffer.concat(centralChunks);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(0, 4);
  end.writeUInt16LE(0, 6);
  end.writeUInt16LE(entries.length, 8);
  end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(centralDirectory.length, 12);
  end.writeUInt32LE(localOffset, 16);
  end.writeUInt16LE(0, 20);
  return Buffer.concat([...localChunks, centralDirectory, end]);
}

const entries = collectEntries();
fs.writeFileSync(tarOutput, createGzip(createTar(entries)));
fs.writeFileSync(zipOutput, createZip(entries));
