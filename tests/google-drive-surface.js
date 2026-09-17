#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const discoveryPath = path.join(root, 'vendor/google-drive/drive.v3.json');
const surfacePath = path.join(root, 'commands/google-drive-v3-methods.tsv');

const discovery = JSON.parse(fs.readFileSync(discoveryPath, 'utf8'));
const surfaceText = fs.readFileSync(surfacePath, 'utf8').trim();

function methodRecord(method) {
  const description = method.description || '';
  return [
    method.id,
    method.httpMethod,
    method.path,
    method.request ? 'json' : 'none',
    method.mediaUpload ? 'resumable' : 'none',
    /^Deprecated:/.test(description) ? 'deprecated' : 'current',
  ];
}

const expected = new Map();
for (const resource of Object.values(discovery.resources || {})) {
  for (const method of Object.values(resource.methods || {})) {
    const record = methodRecord(method);
    if (expected.has(record[0])) {
      throw new Error(`duplicate discovery method id: ${record[0]}`);
    }
    expected.set(record[0], record);
  }
}

const actual = new Map();
for (const line of surfaceText.split('\n')) {
  if (!line || line.startsWith('#')) continue;
  const fields = line.split('\t');
  if (fields.length !== 6) {
    throw new Error(`surface row must have 6 tab-separated fields: ${line}`);
  }
  if (actual.has(fields[0])) {
    throw new Error(`duplicate surface method id: ${fields[0]}`);
  }
  actual.set(fields[0], fields);
}

const failures = [];
for (const [methodId, expectedRecord] of expected) {
  const actualRecord = actual.get(methodId);
  if (!actualRecord) {
    failures.push(`missing method: ${methodId}`);
    continue;
  }
  if (actualRecord.join('\t') !== expectedRecord.join('\t')) {
    failures.push(
      `method drift: ${methodId}\n` +
      `  expected ${expectedRecord.join('\t')}\n` +
      `  actual   ${actualRecord.join('\t')}`
    );
  }
}
for (const methodId of actual.keys()) {
  if (!expected.has(methodId)) {
    failures.push(`surface method absent from discovery mirror: ${methodId}`);
  }
}

if (failures.length) {
  process.stderr.write(`${failures.join('\n')}\n`);
  process.exit(1);
}

process.stdout.write(
  `Google Drive command surface matches ${expected.size} pinned discovery methods\n`
);
