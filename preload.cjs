'use strict';

// Claude Code 2.1.210 has no supported setting for hiding its hardcoded
// "API Usage Billing" welcome label. Filter only that exact rendered phrase
// in terminal output; do not modify the signed Claude binary or conversation data.
const csi = '\\x1b\\[[0-?]*[ -\\/]*[@-~]';
const positionedBilling = new RegExp(
  `${csi}·${csi}API${csi}Usage${csi}Billing`,
  'g',
);

function terminalPhrasePattern(phrase) {
  const separator = `(?:${csi})*`;
  return [...phrase]
    .map((character) => character.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'))
    .join(separator);
}

function replaceTerminalPhrase(text, phrase, replacement) {
  return text.replace(new RegExp(terminalPhrasePattern(phrase), 'g'), replacement);
}

function withoutBillingLabel(text) {
  return replaceTerminalPhrase(text.replace(positionedBilling, ''), '· API Usage Billing', '');
}

// Claude Code owns the session ID, but users launched this session through
// Claudex. Keep the generated resume instruction on the same authenticated
// model path. Preserve any ANSI positioning between the command and flag.
const resumeCommand = new RegExp(
  `\\bclaude((?:${csi})*[ \\t]+(?:${csi})*(?:--resume|-r|-resume)\\b)`,
  'g',
);

function filterClaudexOutput(text) {
  let filtered = withoutBillingLabel(text).replace(resumeCommand, 'claudex$1');
  for (const [phrase, replacement] of [
    ['Opus Plan Mode', 'GPT-5.6 Solplan'],
    ['Opus Plan', 'GPT-5.6 Solplan'],
    ['Opus in plan mode, else Sonnet', 'GPT-5.6 Sol in plan mode, else GPT-5.6 Terra'],
    ['Use Opus in plan mode, Sonnet otherwise', 'Use GPT-5.6 Sol in plan mode, GPT-5.6 Terra otherwise'],
  ]) {
    filtered = replaceTerminalPhrase(filtered, phrase, replacement);
  }
  return filtered;
}

// Claude Code's plan/execution switching is implemented by its built-in
// `opusplan` selector. Expose the provider-accurate `/model solplan` spelling
// without introducing a fake upstream model. For normal character-by-character
// TTY input, replace only the final word just before Enter. For a pasted full
// command, rewrite it before Claude Code sees the chunk.
let currentInputLine = '';
function trackInputLine(text) {
  for (const character of text) {
    if (character === '\r' || character === '\n') currentInputLine = '';
    else if (character === '\x15') currentInputLine = '';
    else if (character === '\x7f' || character === '\b') currentInputLine = currentInputLine.slice(0, -1);
    else if (character >= ' ' && character !== '\x7f') currentInputLine += character;
  }
}

function rewriteSolplanInput(text) {
  const pasted = text.replace(/(^|[\r\n])\/model[ \t]+solplan(?=[\r\n])/gi, '$1/model opusplan');
  if (pasted !== text) {
    process.env.CLAUDEX_MODEL_MODE = 'solplan';
    trackInputLine(pasted);
    return pasted;
  }
  if (/^[\r\n]+$/.test(text) && currentInputLine.trim().toLowerCase() === '/model solplan') {
    process.env.CLAUDEX_MODEL_MODE = 'solplan';
    currentInputLine = '';
    return `${'\x7f'.repeat('solplan'.length)}opusplan${text}`;
  }
  trackInputLine(text);
  return text;
}

if (process.stdin.isTTY || process.env.CLAUDEX_TEST_TTY_INPUT === '1') {
  const rewriteInputChunk = (original) => {
    const encoding = Buffer.isBuffer(original) ? 'utf8' : undefined;
    const decoded = Buffer.isBuffer(original) ? original.toString(encoding) : original;
    if (typeof decoded !== 'string') return original;
    const rewritten = rewriteSolplanInput(decoded);
    return rewritten === decoded || !Buffer.isBuffer(original) ? rewritten : Buffer.from(rewritten, encoding);
  };

  // Bun's native stdin implementation dispatches raw-mode input directly to
  // registered listeners instead of consistently calling the JavaScript
  // EventEmitter.emit method. Wrap the listener boundary, and the read method
  // used by readable-mode consumers, so both Claude Code input paths see the
  // same exact-command alias.
  const listenerWrappers = new WeakMap();
  const wrappedListeners = new WeakSet();
  const wrapDataListener = (listener) => {
    if (typeof listener !== 'function' || wrappedListeners.has(listener)) return listener;
    if (listenerWrappers.has(listener)) return listenerWrappers.get(listener);
    const wrapped = function claudexInputListener(chunk, ...rest) {
      return listener.call(this, rewriteInputChunk(chunk), ...rest);
    };
    listenerWrappers.set(listener, wrapped);
    wrappedListeners.add(wrapped);
    return wrapped;
  };

  for (const method of ['on', 'addListener', 'once', 'prependListener', 'prependOnceListener']) {
    if (typeof process.stdin[method] !== 'function') continue;
    const original = process.stdin[method];
    process.stdin[method] = function claudexInputRegistration(event, listener, ...rest) {
      return original.call(this, event, event === 'data' ? wrapDataListener(listener) : listener, ...rest);
    };
  }
  for (const method of ['off', 'removeListener']) {
    if (typeof process.stdin[method] !== 'function') continue;
    const original = process.stdin[method];
    process.stdin[method] = function claudexInputRemoval(event, listener, ...rest) {
      const registered = event === 'data' && listenerWrappers.has(listener) ? listenerWrappers.get(listener) : listener;
      return original.call(this, event, registered, ...rest);
    };
  }

  if (typeof process.stdin.read === 'function') {
    const originalRead = process.stdin.read;
    process.stdin.read = function claudexInputRead(...args) {
      const chunk = originalRead.apply(this, args);
      return chunk == null ? chunk : rewriteInputChunk(chunk);
    };
  }
}

function installOutputFilter(stream) {
  const originalWrite = stream.write.bind(stream);
  stream.write = function claudexFilteredWrite(chunk, encoding, callback) {
    if (Buffer.isBuffer(chunk)) {
      const decoded = chunk.toString(typeof encoding === 'string' ? encoding : 'utf8');
      const filtered = filterClaudexOutput(decoded);
      if (filtered !== decoded) {
        chunk = Buffer.from(filtered, typeof encoding === 'string' ? encoding : 'utf8');
      }
    } else if (typeof chunk === 'string') {
      chunk = filterClaudexOutput(chunk);
    }
    return originalWrite(chunk, encoding, callback);
  };
}

installOutputFilter(process.stdout);
installOutputFilter(process.stderr);

module.exports = { filterClaudexOutput, rewriteSolplanInput };
