'use strict';

// Claude Code 2.1.211 has no supported setting for replacing its hardcoded
// "API Usage Billing" welcome label for a custom API-compatible backend.
// Claudex replaces only that one startup field with the real ChatGPT plan.
// It never modifies the signed Claude binary or conversation data.
const csi = '\\x1b\\[[0-?]*[ -\\/]*[@-~]';
const positionedBilling = new RegExp(
  `${csi}·${csi}API${csi}Usage${csi}Billing`,
  'g',
);
const splitPositionedBilling = new RegExp(`· API Usage Bil${csi}ing`, 'g');
const welcomeBillingColumns = /\x1b\[(\d+)GAPI\x1b\[(\d+)GUsage\x1b\[(\d+)GBilling/;
const billingFieldWidth = 'API Usage Billing'.length;
const welcomeFrameMarker = '\x1b[?1049h';

function chatGptPlanLabel(value = process.env.CLAUDEX_CHATGPT_PLAN_LABEL) {
  const label = typeof value === 'string' ? value.trim() : '';
  return /^ChatGPT(?: (?:Free|Go|Plus|Pro|Business|Enterprise|Edu|Teachers|K-12|Healthcare))?$/.test(label)
    ? label
    : 'ChatGPT';
}

function replaceWelcomeBillingColumns(text, label = chatGptPlanLabel(), options = {}) {
  if (options.requireWelcomeFrame
      && (!text.includes(welcomeFrameMarker) || !text.includes('Claude Code'))) {
    return { output: text, replaced: false };
  }
  let replaced = false;
  const output = text.replace(welcomeBillingColumns, (match, apiColumnText, usageColumnText, billingColumnText) => {
    const apiColumn = Number.parseInt(apiColumnText, 10);
    const usageColumn = Number.parseInt(usageColumnText, 10);
    const billingColumn = Number.parseInt(billingColumnText, 10);
    if (usageColumn !== apiColumn + 4 || billingColumn !== apiColumn + 10) return match;

    // Consumer labels fit the native 17-cell field. The two 18-character
    // workspace labels use the blank cell immediately before the field so the
    // exact plan remains visible without moving the native end cursor.
    const overflow = Math.max(0, label.length - billingFieldWidth);
    if (overflow > 1 || apiColumn <= overflow) return match;
    const replacement = overflow === 0 ? label.padEnd(billingFieldWidth, ' ') : label;
    replaced = true;
    return `\x1b[${apiColumn - overflow}G${replacement}`;
  });
  return { output, replaced };
}

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

function withChatGptPlanLabel(text, label = chatGptPlanLabel()) {
  const positioned = replaceWelcomeBillingColumns(text, label).output;
  const replacement = `· ${label}`;
  return replaceTerminalPhrase(
    positioned.replace(positionedBilling, replacement).replace(splitPositionedBilling, replacement),
    '· API Usage Billing',
    replacement,
  );
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
      new RegExp(`(${terminalPhrasePattern(label)})\\[[0-9;]*m`, 'g'),
      '$1',
    );
  }
  return filtered;
}

function filterClaudexOutput(text) {
  let filtered = replaceModelFooterLabels(withChatGptPlanLabel(text).replace(resumeCommand, 'claudex$1'));
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

function installWelcomePlanFilter() {
  const testOverride = process.env.CLAUDEX_TEST_WELCOME_FILTER === '1';
  if (process.env.CLAUDEX_INTERACTIVE_TUI !== '1'
      || (!process.stdout.isTTY && !testOverride)
      || !process.env.CLAUDEX_CHATGPT_PLAN_LABEL) return;

  const originalWrite = process.stdout.write;
  let inspectedBytes = 0;
  let active = true;
  let sawAlternateScreen = false;
  let sawClaudeCode = false;
  const restore = () => {
    if (!active) return;
    active = false;
    if (process.stdout.write === filteredWrite) process.stdout.write = originalWrite;
  };
  function filterWelcomeChunk(chunk, encoding) {
    let output = chunk;
    let replaced = false;
    if (typeof chunk === 'string') {
      sawAlternateScreen ||= chunk.includes(welcomeFrameMarker);
      sawClaudeCode ||= chunk.includes('Claude Code');
      const result = sawAlternateScreen && sawClaudeCode
        ? replaceWelcomeBillingColumns(chunk)
        : { output: chunk, replaced: false };
      output = result.output;
      replaced = result.replaced;
      inspectedBytes += Buffer.byteLength(chunk, typeof encoding === 'string' ? encoding : 'utf8');
    } else if (Buffer.isBuffer(chunk) || chunk instanceof Uint8Array) {
      const source = Buffer.from(chunk.buffer, chunk.byteOffset, chunk.byteLength);
      const sourceText = source.toString('latin1');
      sawAlternateScreen ||= sourceText.includes(welcomeFrameMarker);
      sawClaudeCode ||= sourceText.includes('Claude Code');
      const result = sawAlternateScreen && sawClaudeCode
        ? replaceWelcomeBillingColumns(sourceText)
        : { output: sourceText, replaced: false };
      if (result.replaced) output = Buffer.from(result.output, 'latin1');
      replaced = result.replaced;
      inspectedBytes += source.length;
    }
    // Claude Code writes the alternate-screen/title prelude separately from
    // the positioned banner. Carry only those two booleans across writes; do
    // not buffer, decode, or reorder any terminal bytes.
    if (replaced || inspectedBytes >= 1024 * 1024) restore();
    return output;
  }
  function filteredWrite(chunk, encoding, callback) {
    if (!active) return originalWrite.call(this, chunk, encoding, callback);
    const output = filterWelcomeChunk(chunk, encoding);
    return originalWrite.call(this, output, encoding, callback);
  }

  process.stdout.write = filteredWrite;
  const timeout = setTimeout(restore, 15000);
  timeout.unref?.();
}

// Claude Code's plan/execution switching is implemented by its built-in
// `opusplan` selector. Expose the provider-accurate `/model solplan` spelling
// without introducing a fake upstream model. The terminal sends bytes, not
// JavaScript characters: keep those bytes untouched and track UTF-8 only as
// metadata so an arbitrary read boundary can never corrupt a prompt.
const ESC = 0x1b;
const CR = 0x0d;
const LF = 0x0a;
const DEL = 0x7f;
const bracketedPasteEnd = [ESC, 0x5b, 0x32, 0x30, 0x31, 0x7e];

function utf8SequenceLength(byte) {
  if (byte >= 0xc2 && byte <= 0xdf) return 2;
  if (byte >= 0xe0 && byte <= 0xef) return 3;
  if (byte >= 0xf0 && byte <= 0xf4) return 4;
  return 1;
}

class InputAliasRewriter {
  constructor() {
    this.line = [];
    this.cursor = 0;
    this.reliable = true;
    this.control = null;
    this.bracketedPaste = false;
    this.pendingUtf8 = null;
  }

  rewrite(original) {
    const isString = typeof original === 'string';
    if (!isString && !Buffer.isBuffer(original) && !(original instanceof Uint8Array)) return original;
    const input = isString
      ? Buffer.from(original, 'utf8')
      : Buffer.from(original.buffer, original.byteOffset, original.byteLength);

    for (const unit of this.line) {
      unit.start = null;
      unit.end = null;
    }
    if (this.pendingUtf8) this.pendingUtf8.start = null;

    const output = [];
    for (const byte of input) this.processByte(byte, output);
    const rewritten = Buffer.from(output);
    if (isString) return rewritten.toString('utf8');
    return rewritten.equals(input) && Buffer.isBuffer(original) ? original : rewritten;
  }

  processByte(byte, output) {
    if (this.control) {
      const start = output.length;
      output.push(byte);
      this.control.push({ byte, start, end: output.length });
      if (this.bracketedPaste) this.continueBracketedPasteControl();
      else this.continueControl();
      return;
    }

    if (byte === ESC) {
      const start = output.length;
      output.push(byte);
      this.control = [{ byte, start, end: output.length }];
      return;
    }

    if (!this.bracketedPaste && (byte === CR || byte === LF)) {
      this.submit(output, byte);
      return;
    }

    const start = output.length;
    output.push(byte);
    this.consumeLogicalByte(byte, start, output.length);
  }

  continueBracketedPasteControl() {
    const bytes = this.control.map((entry) => entry.byte);
    const isPrefix = bytes.every((byte, index) => byte === bracketedPasteEnd[index]);
    if (isPrefix && bytes.length < bracketedPasteEnd.length) return;
    if (isPrefix) {
      this.control = null;
      this.bracketedPaste = false;
      return;
    }

    // An ESC that is not the paste terminator is literal pasted content.
    const literal = this.control;
    this.control = null;
    for (const entry of literal) this.consumeLogicalByte(entry.byte, entry.start, entry.end);
  }

  continueControl() {
    const bytes = this.control.map((entry) => entry.byte);
    if (bytes.length === 1) return;
    if (bytes[1] !== 0x5b) {
      this.control = null;
      return;
    }
    const final = bytes[bytes.length - 1];
    if (bytes.length < 3 || final < 0x40 || final > 0x7e) {
      if (bytes.length > 64) this.control = null;
      return;
    }
    this.control = null;
    this.applyCsi(Buffer.from(bytes.slice(2, -1)).toString('ascii'), final);
  }

  applyCsi(parameters, final) {
    const count = Math.max(1, Number.parseInt(parameters, 10) || 1);
    if (final === 0x44) { // Cursor left.
      if (this.reliable) this.cursor = Math.max(0, this.cursor - count);
    } else if (final === 0x43) { // Cursor right.
      if (this.reliable) this.cursor = Math.min(this.line.length, this.cursor + count);
    } else if (final === 0x48 || (final === 0x7e && /^(1|7)$/.test(parameters))) {
      if (this.reliable) this.cursor = 0;
    } else if (final === 0x46 || (final === 0x7e && /^(4|8)$/.test(parameters))) {
      if (this.reliable) this.cursor = this.line.length;
    } else if (final === 0x7e && parameters === '3') { // Delete.
      if (this.reliable && this.cursor < this.line.length) this.line.splice(this.cursor, 1);
    } else if (final === 0x7e && parameters === '200') {
      this.bracketedPaste = true;
    } else if (final === 0x41 || final === 0x42) {
      // History contents belong to Claude Code and cannot be reconstructed.
      this.reliable = false;
    }
  }

  consumeLogicalByte(byte, start, end) {
    if (this.pendingUtf8) {
      if (byte >= 0x80 && byte <= 0xbf) {
        this.pendingUtf8.bytes.push(byte);
        this.pendingUtf8.end = this.pendingUtf8.start == null ? null : end;
        if (this.pendingUtf8.bytes.length === this.pendingUtf8.expected) this.commitUtf8();
        return;
      }
      this.commitInvalidUtf8();
    }

    if (byte === CR || byte === LF) {
      this.line = [];
      this.cursor = 0;
      this.reliable = true;
    } else if (byte === 0x03 || byte === 0x15) { // Ctrl-C / Ctrl-U.
      this.line = [];
      this.cursor = 0;
      this.reliable = true;
    } else if (byte === 0x01) { // Ctrl-A.
      if (this.reliable) this.cursor = 0;
    } else if (byte === 0x05) { // Ctrl-E.
      if (this.reliable) this.cursor = this.line.length;
    } else if (byte === DEL || byte === 0x08) {
      if (this.reliable && this.cursor > 0) {
        this.line.splice(this.cursor - 1, 1);
        this.cursor -= 1;
      }
    } else if (byte === 0x04) { // Ctrl-D.
      if (this.reliable && this.cursor < this.line.length) this.line.splice(this.cursor, 1);
    } else if (byte === 0x09) {
      this.insertUnit('\t', start, end);
    } else if (byte >= 0x20 && byte <= 0x7e) {
      this.insertUnit(String.fromCharCode(byte), start, end);
    } else if (byte >= 0x80) {
      const expected = utf8SequenceLength(byte);
      if (expected === 1) this.insertUnit('\ufffd', start, end);
      else this.pendingUtf8 = { bytes: [byte], expected, start, end };
    }
  }

  insertUnit(text, start, end) {
    if (!this.reliable) return;
    this.line.splice(this.cursor, 0, { text, start, end });
    this.cursor += 1;
  }

  commitUtf8() {
    const pending = this.pendingUtf8;
    this.pendingUtf8 = null;
    this.insertUnit(Buffer.from(pending.bytes).toString('utf8'), pending.start, pending.end);
  }

  commitInvalidUtf8() {
    const pending = this.pendingUtf8;
    this.pendingUtf8 = null;
    for (let index = 0; index < pending.bytes.length; index += 1) {
      this.insertUnit('\ufffd', index === 0 ? pending.start : null, index === pending.bytes.length - 1 ? pending.end : null);
    }
  }

  submit(output, newline) {
    if (this.pendingUtf8) this.commitInvalidUtf8();
    const line = this.reliable ? this.line.map((unit) => unit.text).join('') : '';
    const solplan = line.match(/^\/model[ \t]+solplan[ \t]*$/i);
    if (solplan) {
      const prefix = line.match(/^\/model[ \t]+/i)[0];
      const argumentStart = [...prefix].length;
      const replacedUnits = this.line.slice(argumentStart);
      const first = replacedUnits[0];
      const contiguous = first && replacedUnits.every((unit, index) => (
        unit.start != null && unit.end != null
        && (index === 0 || replacedUnits[index - 1].end === unit.start)
      ));
      if (contiguous) {
        output.splice(first.start, replacedUnits[replacedUnits.length - 1].end - first.start,
          ...Buffer.from('opusplan', 'ascii'));
      } else {
        if (this.cursor < this.line.length) output.push(ESC, 0x5b, 0x46);
        output.push(...Array(replacedUnits.length).fill(DEL), ...Buffer.from('opusplan', 'ascii'));
      }
      process.env.CLAUDEX_MODEL_MODE = 'solplan';
    } else if (/^\/model(?:[ \t]+.*)?$/i.test(line)) {
      delete process.env.CLAUDEX_MODEL_MODE;
    }
    output.push(newline);
    this.line = [];
    this.cursor = 0;
    this.reliable = true;
  }
}

function createInputRewriter() {
  return new InputAliasRewriter();
}

const defaultInputRewriter = createInputRewriter();
function rewriteSolplanInput(text) {
  return defaultInputRewriter.rewrite(text);
}

if (process.stdin.isTTY || process.env.CLAUDEX_TEST_TTY_INPUT === '1') {
  // Bun's native stdin implementation dispatches raw-mode input directly to
  // registered listeners instead of consistently calling the JavaScript
  // EventEmitter.emit method. Wrap the listener boundary, and the read method
  // used by readable-mode consumers, so both Claude Code input paths see the
  // same exact-command alias.
  const listenerWrappers = new WeakMap();
  const wrappedListeners = new WeakSet();
  let registeringOnceWrapper = false;
  const wrapDataListener = (listener) => {
    if (typeof listener !== 'function' || wrappedListeners.has(listener)) return listener;
    if (listenerWrappers.has(listener)) return listenerWrappers.get(listener);
    const rewriter = createInputRewriter();
    const wrapped = function claudexInputListener(chunk, ...rest) {
      return listener.call(this, rewriter.rewrite(chunk), ...rest);
    };
    listenerWrappers.set(listener, wrapped);
    wrappedListeners.add(wrapped);
    return wrapped;
  };

  for (const method of ['on', 'addListener', 'once', 'prependListener', 'prependOnceListener']) {
    if (typeof process.stdin[method] !== 'function') continue;
    const original = process.stdin[method];
    process.stdin[method] = function claudexInputRegistration(event, listener, ...rest) {
      if (registeringOnceWrapper) return original.call(this, event, listener, ...rest);
      const registered = event === 'data' ? wrapDataListener(listener) : listener;
      if (event !== 'data' || (method !== 'once' && method !== 'prependOnceListener')) {
        return original.call(this, event, registered, ...rest);
      }
      // Node implements once() through this.on(). Do not wrap its internal
      // once-wrapper a second time after wrapping the user's listener here.
      registeringOnceWrapper = true;
      try {
        return original.call(this, event, registered, ...rest);
      } finally {
        registeringOnceWrapper = false;
      }
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
    const readableRewriter = createInputRewriter();
    process.stdin.read = function claudexInputRead(...args) {
      const chunk = originalRead.apply(this, args);
      // Data-mode consumers are transformed once at their listener boundary.
      // Native stream machinery may call read() internally before emitting
      // that same chunk, so rewriting here as well would apply edits twice.
      if (chunk == null || this.listenerCount('data') > 0) return chunk;
      return readableRewriter.rewrite(chunk);
    };
  }
}

// Keep all process output native except for the one welcome-field write above.
// The replacement preserves Claude Code's absolute cursor anchor, fills the
// original field width, restores the native writer immediately, and never runs
// for print/JSON output.
installWelcomePlanFilter();

module.exports = {
  chatGptPlanLabel,
  createInputRewriter,
  filterClaudexOutput,
  replaceWelcomeBillingColumns,
  rewriteSolplanInput,
};
