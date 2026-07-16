import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const preloadPath = path.join(root, 'preload.cjs');
const require = createRequire(import.meta.url);
for (const name of ['CLAUDEX_INTERACTIVE_TUI', 'CLAUDEX_CHATGPT_PLAN_LABEL', 'CLAUDEX_TEST_WELCOME_FILTER']) {
  delete process.env[name];
}
const {
  chatGptPlanLabel,
  createInputRewriter,
  filterClaudexOutput,
  replaceWelcomeBillingColumns,
} = require(preloadPath);

function asBuffer(value) {
  return Buffer.isBuffer(value) ? value : Buffer.from(value, 'utf8');
}

function rewriteChunks(chunks) {
  const rewriter = createInputRewriter();
  return Buffer.concat(chunks.map((chunk) => asBuffer(rewriter.rewrite(chunk))));
}

function chunksAtEveryByte(input) {
  return [...input].map((byte) => Buffer.from([byte]));
}

function applyInput(bytes) {
  const text = bytes.toString('utf8');
  const submitted = [];
  const line = [];
  let cursor = 0;
  let bracketedPaste = false;

  const insert = (character) => {
    line.splice(cursor, 0, character);
    cursor += 1;
  };
  const applyCsi = (parameters, final) => {
    const count = Math.max(1, Number.parseInt(parameters, 10) || 1);
    if (final === 'D') cursor = Math.max(0, cursor - count);
    else if (final === 'C') cursor = Math.min(line.length, cursor + count);
    else if (final === 'H' || (final === '~' && /^(1|7)$/.test(parameters))) cursor = 0;
    else if (final === 'F' || (final === '~' && /^(4|8)$/.test(parameters))) cursor = line.length;
    else if (final === '~' && parameters === '3' && cursor < line.length) line.splice(cursor, 1);
    else if (final === '~' && parameters === '200') bracketedPaste = true;
    else if (final === '~' && parameters === '201') bracketedPaste = false;
  };

  for (let index = 0; index < text.length;) {
    const character = String.fromCodePoint(text.codePointAt(index));
    const characterLength = character.length;
    if (character === '\x1b' && text[index + 1] === '[') {
      let end = index + 2;
      while (end < text.length && !/[@-~]/.test(text[end])) end += 1;
      if (end < text.length) {
        const parameters = text.slice(index + 2, end);
        const final = text[end];
        if (!bracketedPaste || `${parameters}${final}` === '201~') applyCsi(parameters, final);
        else for (const literal of text.slice(index, end + 1)) insert(literal);
        index = end + 1;
        continue;
      }
    }
    if (character === '\r' || character === '\n') {
      submitted.push(line.join(''));
      line.length = 0;
      cursor = 0;
    } else if (character === '\x03' || character === '\x15') {
      line.length = 0;
      cursor = 0;
    } else if (character === '\x01') cursor = 0;
    else if (character === '\x05') cursor = line.length;
    else if (character === '\x7f' || character === '\b') {
      if (cursor > 0) {
        line.splice(cursor - 1, 1);
        cursor -= 1;
      }
    } else if (character === '\x04') {
      if (cursor < line.length) line.splice(cursor, 1);
    } else if (character >= ' ') insert(character);
    index += characterLength;
  }
  return { line: line.join(''), submitted };
}

function assertSubmitsOpusplan(output, label) {
  assert.deepEqual(applyInput(output).submitted, ['/model opusplan'], label);
}

// Loading the preload must not wrap either process output stream. This protects
// human print output, JSON/stream-JSON contracts, callbacks, and backpressure.
const machinePayload = JSON.stringify({
  type: 'result',
  result: 'Opus Plan Mode; claude --resume abc; /model opus; 😀',
});
const untouched = spawnSync(process.execPath, ['-e', `
  const assert = require('node:assert/strict');
  const stdoutWrite = process.stdout.write;
  const stderrWrite = process.stderr.write;
  require(${JSON.stringify(preloadPath)});
  assert.equal(process.stdout.write, stdoutWrite);
  assert.equal(process.stderr.write, stderrWrite);
  process.stdout.write(${JSON.stringify(machinePayload)});
  process.stderr.write('Opus Plan Mode; claude --resume abc; /model opus');
`], { encoding: 'utf8' });
assert.equal(untouched.status, 0, untouched.stderr);
assert.equal(untouched.stdout, machinePayload);
assert.equal(untouched.stderr, 'Opus Plan Mode; claude --resume abc; /model opus');

// Output is an opaque byte stream. Exercise the exact cases that a text-based
// write wrapper breaks: UTF-8 split across calls, invalid UTF-8, fullscreen
// ANSI frames, offset Uint8Array views, managed-looking machine data, callback
// order, and the native write return value.
const opaqueParts = [
  Buffer.from([0xf0, 0x9f]),
  Buffer.from([0x98, 0x80]),
  Buffer.from([0xf0, 0x28, 0x8c, 0x28]),
  Buffer.from('\x1b[?1049h\x1b[2J\x1b[H/model opus\x1b[?1049l'),
  Buffer.from('{"result":"Opus Plan Mo'),
  Buffer.from('de","resume":"claude --res'),
  Buffer.from('ume abc","model":"/model op'),
  Buffer.from('us"}'),
];
const opaqueOutput = spawnSync(process.execPath, ['-r', preloadPath, '-e', `
  const parts = ${JSON.stringify(opaqueParts.map((part) => part.toString('base64')))}
    .map((part) => Buffer.from(part, 'base64'));
  const callbackOrder = [];
  const returnValues = [];
  for (let index = 0; index < parts.length; index += 1) {
    const padded = Buffer.concat([Buffer.from([0xaa, 0xbb]), parts[index], Buffer.from([0xcc])]);
    const view = new Uint8Array(padded.buffer, padded.byteOffset + 2, parts[index].length);
    returnValues.push(process.stdout.write(view, () => {
      callbackOrder.push(index);
      if (callbackOrder.length === parts.length) {
        process.stderr.write(JSON.stringify({ callbackOrder, returnValues }));
      }
    }));
  }
`], { maxBuffer: 1024 * 1024 });
assert.equal(opaqueOutput.status, 0, opaqueOutput.stderr.toString());
assert.deepEqual(opaqueOutput.stdout, Buffer.concat(opaqueParts), 'stdout bytes are never decoded or rewritten');
assert.deepEqual(
  JSON.parse(opaqueOutput.stderr.toString()),
  {
    callbackOrder: [0, 1, 2, 3, 4, 5, 6, 7],
    returnValues: [true, true, true, true, true, true, true, true],
  },
  'native write callbacks and return values are preserved',
);

// The pure compatibility helper remains available, but valid ANSI state must
// survive it. Only the known malformed no-ESC SGR token is discarded.
assert.equal(
  filterClaudexOutput('\x1b[31m/model opus\x1b[0m normal'),
  '\x1b[31m/model GPT-5.6 Sol\x1b[0m normal',
);
assert.equal(filterClaudexOutput('/model opus[1m normal'), '/model GPT-5.6 Sol normal');
assert.equal(filterClaudexOutput('Opus Plan Mode'), 'GPT-5.6 Solplan');
assert.equal(filterClaudexOutput('· API Usage Billing'), '· ChatGPT');
assert.equal(chatGptPlanLabel('ChatGPT Pro'), 'ChatGPT Pro');
assert.equal(chatGptPlanLabel('ChatGPT Pro\x1b[2J'), 'ChatGPT');
assert.deepEqual(
  replaceWelcomeBillingColumns('\x1b[43GAPI\x1b[47GUsage\x1b[53GBilling', 'ChatGPT Pro'),
  { output: '\x1b[43GChatGPT Pro      ', replaced: true },
);
assert.deepEqual(
  replaceWelcomeBillingColumns('\x1b[43GAPI\x1b[47GUsage\x1b[53GBilling', 'ChatGPT Enterprise'),
  { output: '\x1b[42GChatGPT Enterprise', replaced: true },
);
assert.deepEqual(
  replaceWelcomeBillingColumns('\x1b[1GAPI\x1b[999GUsage\x1b[2GBilling', 'ChatGPT Pro'),
  { output: '\x1b[1GAPI\x1b[999GUsage\x1b[2GBilling', replaced: false },
);
assert.deepEqual(
  replaceWelcomeBillingColumns('\x1b[43GAPI\x1b[47GUsage\x1b[53GBilling|\x1b[43GAPI\x1b[47GUsage\x1b[53GBilling', 'ChatGPT Pro'),
  { output: '\x1b[43GChatGPT Pro      |\x1b[43GAPI\x1b[47GUsage\x1b[53GBilling', replaced: true },
);

// Interactive startup filtering is intentionally one-shot: it rewrites only
// the positioned billing field, preserves native write return/callback
// behavior, then restores stdout before later fullscreen frames.
const welcomeProbe = spawnSync(process.execPath, ['-e', `
  const nativeWrite = process.stdout.write;
  require(${JSON.stringify(preloadPath)});
  const wrappedBefore = process.stdout.write !== nativeWrite;
  const callbackOrder = [];
  process.stdout.write(Buffer.from('\\x1b[?1049h\\x1b]0;✳ Claude Code\\x07prefix'));
  const cachedWrite = process.stdout.write;
  const returned = cachedWrite.call(process.stdout, Buffer.from('\\x1b[43GAPI\\x1b[47GUsage\\x1b[53GBilling\\r'), () => callbackOrder.push('welcome'));
  cachedWrite.call(process.stdout, '\\x1b[43GAPI\\x1b[47GUsage\\x1b[53GBilling');
  process.stdout.write('native-followup', () => {
    callbackOrder.push('followup');
    process.stderr.write(JSON.stringify({ wrappedBefore, restored: process.stdout.write === nativeWrite, returned, callbackOrder }));
  });
`], {
  encoding: 'utf8',
  env: {
    ...process.env,
    CLAUDEX_INTERACTIVE_TUI: '1',
    CLAUDEX_CHATGPT_PLAN_LABEL: 'ChatGPT Pro',
    CLAUDEX_TEST_WELCOME_FILTER: '1',
  },
});
assert.equal(welcomeProbe.status, 0, welcomeProbe.stderr);
assert.equal(welcomeProbe.stdout, '\x1b[?1049h\x1b]0;✳ Claude Code\x07prefix\x1b[43GChatGPT Pro      \r\x1b[43GAPI\x1b[47GUsage\x1b[53GBillingnative-followup');
assert.deepEqual(
  JSON.parse(welcomeProbe.stderr),
  { wrappedBefore: true, restored: true, returned: true, callbackOrder: ['welcome', 'followup'] },
);

assert.equal(createInputRewriter().rewrite('/model solplan \r'), '/model opusplan\r');
assert.equal(createInputRewriter().rewrite('/MODEL\tsOlPlAn\r'), '/MODEL\topusplan\r');

const plainCommand = Buffer.from('/model solplan\r');
for (let split = 0; split <= plainCommand.length; split += 1) {
  const output = rewriteChunks([plainCommand.subarray(0, split), plainCommand.subarray(split)]);
  assertSubmitsOpusplan(output, `plain command split at byte ${split}`);
}
assertSubmitsOpusplan(rewriteChunks(chunksAtEveryByte(plainCommand)), 'plain command byte-at-a-time');

const bracketedCommand = Buffer.concat([
  Buffer.from('\x1b[200~'),
  Buffer.from('/model solplan'),
  Buffer.from('\x1b[201~\r'),
]);
for (let split = 0; split <= bracketedCommand.length; split += 1) {
  const output = rewriteChunks([bracketedCommand.subarray(0, split), bracketedCommand.subarray(split)]);
  assertSubmitsOpusplan(output, `bracketed paste split at byte ${split}`);
}
assertSubmitsOpusplan(rewriteChunks(chunksAtEveryByte(bracketedCommand)), 'bracketed paste byte-at-a-time');

for (const sample of ['😀', '€', '界', 'e\u0301']) {
  const sampleBytes = Buffer.from(sample);
  const deleteBytes = Buffer.alloc([...sample].length, 0x7f);
  const input = Buffer.concat([Buffer.from('/model solplan'), sampleBytes, deleteBytes, Buffer.from('\r')]);
  for (let split = 0; split <= input.length; split += 1) {
    const output = rewriteChunks([input.subarray(0, split), input.subarray(split)]);
    assert.notEqual(output.indexOf(sampleBytes), -1, `${JSON.stringify(sample)} bytes preserved at split ${split}`);
    assert.equal(output.indexOf(Buffer.from([0xef, 0xbf, 0xbd])), -1, `${JSON.stringify(sample)} has no replacement character`);
    assertSubmitsOpusplan(output, `${JSON.stringify(sample)} backspace split at byte ${split}`);
  }
  assertSubmitsOpusplan(rewriteChunks(chunksAtEveryByte(input)), `${JSON.stringify(sample)} byte-at-a-time`);
}

assertSubmitsOpusplan(rewriteChunks([
  Buffer.from('/model solplan'), Buffer.from('\x1b[D'), Buffer.from('\r'),
]), 'cursor-left before submit');
assertSubmitsOpusplan(rewriteChunks([
  Buffer.from('/model solplanX'), Buffer.from('\x1b[D'), Buffer.from('\x1b[3~'), Buffer.from('\r'),
]), 'cursor delete repairs command');
assertSubmitsOpusplan(rewriteChunks([
  Buffer.from('/model solplan'), Buffer.from('\x1b[H'), Buffer.from('\x1b[F'), Buffer.from('\r'),
]), 'home/end before submit');

const historyUncertain = rewriteChunks([
  Buffer.from('/model solplan'), Buffer.from('\x1b[A'), Buffer.from('\r'),
]);
assert.equal(historyUncertain.includes(Buffer.from('opusplan')), false, 'unknown history is never rewritten speculatively');
assertSubmitsOpusplan(rewriteChunks([
  Buffer.from('unknown'), Buffer.from('\x1b[A'), Buffer.from('\x15'), Buffer.from('/model solplan\r'),
]), 'Ctrl-U restores reliable tracking after history');

// Exercise the installed data-listener boundary with arbitrary Buffer splits
// and more than one listener. Every consumer must see one equivalent rewrite.
const listenerInput = Buffer.concat([
  Buffer.from('/model solplan'), Buffer.from('😀'), Buffer.from([0x7f, 0x0d]),
]);
const listenerProbe = spawnSync(process.execPath, ['-r', preloadPath, '-e', `
  const received = [[], []];
  const listeners = received.map((target) => (chunk) => target.push(Buffer.from(chunk)));
  process.stdin.on('data', listeners[0]);
  process.stdin.on('data', listeners[1]);
  const input = Buffer.from(${JSON.stringify(listenerInput.toString('base64'))}, 'base64');
  for (let index = 0; index < input.length; index += 1) process.stdin.emit('data', input.subarray(index, index + 1));
  process.stdin.off('data', listeners[0]);
  process.stdin.off('data', listeners[1]);
  process.stdout.write(JSON.stringify(received.map((parts) => Buffer.concat(parts).toString('base64'))));
`], {
  encoding: 'utf8',
  env: { ...process.env, CLAUDEX_TEST_TTY_INPUT: '1' },
});
assert.equal(listenerProbe.status, 0, listenerProbe.stderr);
const listenerOutputs = JSON.parse(listenerProbe.stdout).map((encoded) => Buffer.from(encoded, 'base64'));
assert.deepEqual(listenerOutputs[0], listenerOutputs[1]);
assertSubmitsOpusplan(listenerOutputs[0], 'installed listener wrapper');
assert.equal(listenerOutputs[0].indexOf(Buffer.from('😀')) >= 0, true, 'listener preserves split UTF-8 bytes');

const onceProbe = spawnSync(process.execPath, ['-r', preloadPath, '-e', `
  const received = [];
  process.stdin.once('data', (chunk) => received.push(Buffer.from(chunk).toString('base64')));
  process.stdin.prependOnceListener('data', (chunk) => received.push(Buffer.from(chunk).toString('base64')));
  process.stdin.emit('data', Buffer.from('/model solplan\\r'));
  process.stdout.write(JSON.stringify({ received, mode: process.env.CLAUDEX_MODEL_MODE }));
`], {
  encoding: 'utf8',
  env: { ...process.env, CLAUDEX_TEST_TTY_INPUT: '1' },
});
assert.equal(onceProbe.status, 0, onceProbe.stderr);
const onceResult = JSON.parse(onceProbe.stdout);
assert.equal(onceResult.mode, 'solplan', 'once listeners update model mode exactly once');
assert.equal(onceResult.received.length, 2);
for (const encoded of onceResult.received) {
  assertSubmitsOpusplan(Buffer.from(encoded, 'base64'), 'once listener wrapper');
}

console.log('preload terminal regressions passed');
