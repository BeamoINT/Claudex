'use strict';

// Claude Code 2.1.210 has no supported setting for hiding its hardcoded
// "API Usage Billing" welcome label. Filter only that exact rendered phrase
// at stdout; do not modify the signed Claude binary or any conversation data.
const originalWrite = process.stdout.write.bind(process.stdout);
const csi = '\\x1b\\[[0-?]*[ -\\/]*[@-~]';
const positionedBilling = new RegExp(
  `${csi}·${csi}API${csi}Usage${csi}Billing`,
  'g',
);

function withoutBillingLabel(text) {
  return text.replace(positionedBilling, '');
}

process.stdout.write = function claudexFilteredWrite(chunk, encoding, callback) {
  if (Buffer.isBuffer(chunk)) {
    const decoded = chunk.toString(typeof encoding === 'string' ? encoding : 'utf8');
    const filtered = withoutBillingLabel(decoded);
    if (filtered !== decoded) {
      chunk = Buffer.from(filtered, typeof encoding === 'string' ? encoding : 'utf8');
    }
  } else if (typeof chunk === 'string') {
    chunk = withoutBillingLabel(chunk);
  }
  return originalWrite(chunk, encoding, callback);
};
