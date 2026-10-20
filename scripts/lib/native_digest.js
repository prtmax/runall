#!/usr/bin/env node
'use strict';

const crypto = require('crypto');
const fs = require('fs');

function fail(message) {
  process.stderr.write(`[runall] ${message}\n`);
  process.exit(1);
}

function validateUnicode(value) {
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code >= 0xd800 && code <= 0xdbff) {
      const next = value.charCodeAt(index + 1);
      if (!(next >= 0xdc00 && next <= 0xdfff)) fail('canonical JSON contains invalid Unicode');
      index += 1;
    } else if (code >= 0xdc00 && code <= 0xdfff) {
      fail('canonical JSON contains invalid Unicode');
    }
  }
}

function canonical(value) {
  if (value === null || typeof value === 'boolean') return JSON.stringify(value);
  if (typeof value === 'string') {
    validateUnicode(value);
    return JSON.stringify(value);
  }
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) fail('canonical JSON contains a non-finite number');
    // RFC 8785 uses ECMAScript number serialization, including e+21.
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (typeof value === 'object') {
    return `{${Object.keys(value).sort().map((key) => {
      validateUnicode(key);
      return `${JSON.stringify(key)}:${canonical(value[key])}`;
    }).join(',')}}`;
  }
  fail('canonical JSON contains an unsupported value');
}

function digest(value) {
  return crypto.createHash('sha256').update(canonical(value), 'utf8').digest('hex');
}

if (process.argv.length !== 4 || !['input', 'spec'].includes(process.argv[2])) {
  fail('usage: native_digest.js input|spec BUILD_SPEC.json');
}
const source = fs.readFileSync(process.argv[3], 'utf8');
const integerNames = new Set(['versionCode', 'revision', 'minSdkVersion', 'maxSdkVersion', 'configRevision']);
for (const match of source.matchAll(/"([^"\\]+)"\s*:\s*(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)/g)) {
  const value = Number(match[2]);
  if (!Number.isSafeInteger(value) && integerNames.has(match[1])) {
    fail(`integer is outside the RFC 8785 safe range: ${match[1]}`);
  }
}
const spec = JSON.parse(source);
if (process.argv[2] === 'input') {
  process.stdout.write(`${digest(spec.buildInput)}\n`);
} else {
  const facts = {
    schemaVersion: spec.schemaVersion,
    tenantId: spec.tenantId,
    appId: spec.appId,
    configRevision: spec.configRevision,
    catalogId: spec.catalogId,
    platform: spec.platform,
    targets: spec.targets,
    buildInput: spec.buildInput,
    inputDigest: spec.inputDigest,
    artifactPrefix: spec.artifactPrefix,
  };
  process.stdout.write(`${digest(facts)}\n`);
}
