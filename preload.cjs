'use strict';

// Claude Code 2.1.210 has no supported setting for hiding its hardcoded
// "API Usage Billing" welcome label. Filter only that exact rendered phrase
// in terminal output; do not modify the signed Claude binary or conversation data.
const csi = '\\x1b\\[[0-?]*[ -\\/]*[@-~]';
const positionedBilling = new RegExp(
  `${csi}·${csi}API${csi}Usage${csi}Billing`,
  'g',
);
const splitPositionedBilling = new RegExp(`· API Usage Bil${csi}ing`, 'g');

function terminalPhrasePattern(phrase) {
  const separator = `(?:${csi})*`;
  return [...phrase]
    .map((character) => character === ' '
      ? `(?: |${csi})+`
      : character.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'))
    .join(separator);
}

function replaceTerminalPhrase(text, phrase, replacement) {
  return text.replace(new RegExp(terminalPhrasePattern(phrase), 'g'), replacement);
}

function withoutBillingLabel(text) {
  return replaceTerminalPhrase(text.replace(positionedBilling, '').replace(splitPositionedBilling, ''), '· API Usage Billing', '');
}

// Claude Code owns the session ID, but users launched this session through
// Claudex. Keep the generated resume instruction on the same authenticated
// model path. Preserve any ANSI positioning between the command and flag.
const resumeCommand = new RegExp(
  `\\bclaude((?:${csi})*[ \\t]+(?:${csi})*(?:--resume|-r|-resume)\\b)`,
  'g',
);

const modelFooterLabels = [
  ['/model opusplan', '/model GPT-5.6 Solplan'],
  ['/model opus', '/model GPT-5.6 Sol'],
  ['/model gpt-5.6-sol', '/model GPT-5.6 Sol'],
  ['/model gpt-5.6-terra', '/model GPT-5.6 Terra'],
  ['/model gpt-5.6-luna', '/model GPT-5.6 Luna'],
];

const rateLimitMessages = [
  ['gpt-5.6-sol', 'GPT-5.6 Sol'],
  ['gpt-5.6-terra', 'GPT-5.6 Terra'],
  ['gpt-5.6-luna', 'GPT-5.6 Luna'],
].flatMap(([model, label]) => {
  const replacement = `Your Codex rate limit for ${label} is exhausted. Run /usage-limit to check when it resets, or sign in to another Codex account.`;
  return [
    [`API Error: Request rejected (429) · All credentials for model ${model} are cooling down`, replacement],
    [`429 All credentials for model ${model} are cooling down`, replacement],
    [`All credentials for model ${model} are cooling down`, replacement],
  ];
});

function replaceModelFooterLabels(text) {
  let filtered = text;
  for (const [source, replacement] of modelFooterLabels) {
    filtered = replaceTerminalPhrase(filtered, source, replacement);
  }

  // Claude Code occasionally emits a Select Graphic Rendition token without
  // its ESC byte after the internal footer model name. Remove that orphan only
  // when it immediately follows a model label managed by Claudex.
  for (const [, label] of modelFooterLabels) {
    filtered = filtered.replace(
      new RegExp(`(${terminalPhrasePattern(label)})(?:\\x1b)?\\[[0-9;]*m`, 'g'),
      '$1',
    );
  }
  return filtered;
}

function filterClaudexOutput(text) {
  let filtered = replaceModelFooterLabels(withoutBillingLabel(text).replace(resumeCommand, 'claudex$1'));
  for (const [phrase, replacement] of [
    ['Opus Plan Mode', 'GPT-5.6 Solplan'],
    ['Opus Plan', 'GPT-5.6 Solplan'],
    ['Opus in plan mode, else Sonnet', 'GPT-5.6 Solplan'],
    ['Use Opus in plan mode, Sonnet otherwise', 'Use GPT-5.6 Sol in plan mode, GPT-5.6 Terra otherwise'],
    ...rateLimitMessages,
  ]) {
    filtered = replaceTerminalPhrase(filtered, phrase, replacement);
  }
  return filtered;
}

const streamedPhrases = [
  '· API Usage Billing',
  'Opus Plan Mode',
  'Opus Plan',
  'Opus in plan mode, else Sonnet',
  'Use Opus in plan mode, Sonnet otherwise',
  'claude --resume',
  'claude -resume',
  'claude -r',
  ...modelFooterLabels.map(([source]) => source),
  ...rateLimitMessages.map(([source]) => source),
];

function trailingManagedPrefixStart(text) {
  const visible = [];
  const rawStarts = [];
  const ansi = new RegExp(csi, 'y');
  let incompleteAnsiStart = -1;
  for (let index = 0; index < text.length;) {
    ansi.lastIndex = index;
    const match = ansi.exec(text);
    if (match) {
      index += match[0].length;
      continue;
    }
    if (text[index] === '\x1b' && /^\x1b\[[0-?]*[ -\/]*$/.test(text.slice(index))) {
      incompleteAnsiStart = index;
      break;
    }
    rawStarts.push(index);
    visible.push(text[index]);
    index += 1;
  }
  const rendered = visible.join('');
  let modelFooterStart = -1;
  for (const [source] of modelFooterLabels) {
    const malformedSgr = new RegExp(`${source.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\[[0-9;]*$`).exec(rendered);
    const suffixLength = malformedSgr ? malformedSgr[0].length : (rendered.endsWith(source) ? source.length : 0);
    if (suffixLength > 0) {
      const start = rawStarts[rendered.length - suffixLength];
      modelFooterStart = modelFooterStart < 0 ? start : Math.min(modelFooterStart, start);
    }
  }
  let longest = 0;
  for (const phrase of streamedPhrases) {
    const maximum = Math.min(rendered.length, phrase.length - 1);
    for (let length = maximum; length >= 1; length -= 1) {
      if (length <= longest) break;
      if (phrase.startsWith(rendered.slice(-length))) {
        longest = length;
        break;
      }
    }
  }
  const phraseStart = longest > 0 ? rawStarts[rendered.length - longest] : -1;
  const pendingStarts = [phraseStart, incompleteAnsiStart, modelFooterStart]
    .filter((start) => start >= 0);
  return pendingStarts.length > 0 ? Math.min(...pendingStarts) : -1;
}

// Claude Code's plan/execution switching is implemented by its built-in
// `opusplan` selector. Expose the provider-accurate `/model solplan` spelling
// without introducing a fake upstream model. For normal character-by-character
// TTY input, replace only the final word just before Enter. For a pasted full
// command, rewrite it before Claude Code sees the chunk.
let currentInputLine = '';
function updateModelMode(line) {
  const match = line.trim().match(/^\/model(?:[ \t]+(.+))?$/i);
  if (!match) return;
  if ((match[1] || '').trim().toLowerCase() === 'solplan') process.env.CLAUDEX_MODEL_MODE = 'solplan';
  else delete process.env.CLAUDEX_MODEL_MODE;
}

function trackInputLine(text) {
  for (const character of text) {
    if (character === '\r' || character === '\n') {
      updateModelMode(currentInputLine);
      currentInputLine = '';
    } else if (character === '\x03' || character === '\x15') currentInputLine = '';
    else if (character === '\x7f' || character === '\b') currentInputLine = currentInputLine.slice(0, -1);
    else if (character >= ' ' && character !== '\x7f') currentInputLine += character;
  }
}

function rewriteSolplanInput(text) {
  const submittedModelCommands = text.match(/(?:^|[\r\n])\/model[ \t]+[^\r\n]*(?=[\r\n])/gi) || [];
  for (const command of submittedModelCommands) updateModelMode(command.replace(/^[\r\n]/, ''));
  const pasted = text.replace(/(^|[\r\n])\/model[ \t]+solplan[ \t]*(?=[\r\n])/gi, '$1/model opusplan');
  if (pasted !== text) {
    trackInputLine(pasted);
    process.env.CLAUDEX_MODEL_MODE = 'solplan';
    return pasted;
  }
  if (/^[\r\n]+$/.test(text) && /^\/model[ \t]+solplan[ \t]*$/i.test(currentInputLine)) {
    const replaceLength = currentInputLine.match(/solplan[ \t]*$/i)[0].length;
    process.env.CLAUDEX_MODEL_MODE = 'solplan';
    currentInputLine = '';
    return `${'\x7f'.repeat(replaceLength)}opusplan${text}`;
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
  let pending = '';
  stream.write = function claudexFilteredWrite(chunk, encoding, callback) {
    const buffer = Buffer.isBuffer(chunk);
    const characterEncoding = typeof encoding === 'string' ? encoding : 'utf8';
    const decoded = buffer ? chunk.toString(characterEncoding) : chunk;
    if (typeof decoded !== 'string') return originalWrite(chunk, encoding, callback);

    const combined = pending + decoded;
    const pendingStart = trailingManagedPrefixStart(combined);
    const ready = filterClaudexOutput(pendingStart >= 0 ? combined.slice(0, pendingStart) : combined);
    pending = pendingStart >= 0 ? combined.slice(pendingStart) : '';
    chunk = buffer ? Buffer.from(ready, characterEncoding) : ready;
    return originalWrite(chunk, encoding, callback);
  };

  process.on('exit', () => {
    if (pending) originalWrite(filterClaudexOutput(pending));
    pending = '';
  });
}

// Fullscreen Claude Code owns cursor placement, erase regions, and redraw
// timing. Changing the byte length of those live frames after layout can leave
// clipped input, duplicate cursors, or orphaned footer characters. Keep the
// interactive TUI byte-for-byte native; model metadata and the supported
// status-line hook already provide Claudex labels there. The filter remains
// available for non-interactive output and focused diagnostics.
const interactiveTui = process.env.CLAUDEX_INTERACTIVE_TUI === '1'
  || process.env.CLAUDEX_TEST_INTERACTIVE_TUI === '1'
  || Boolean(process.stdout.isTTY && process.stdin.isTTY);
if (!interactiveTui) {
  installOutputFilter(process.stdout);
  installOutputFilter(process.stderr);
}

module.exports = { filterClaudexOutput, rewriteSolplanInput };
