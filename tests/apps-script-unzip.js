'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const source = path.join(
  __dirname,
  '..',
  'google-apps-script',
  'unzip-drive.gs'
);

vm.runInThisContext(fs.readFileSync(source, 'utf8'), {filename: source});

function equal(actual, expected) {
  if (actual !== expected) {
    throw new Error(`expected ${JSON.stringify(expected)}, found ${JSON.stringify(actual)}`);
  }
}

function rejects(value) {
  let rejected = false;
  try {
    safe_archive_path(value);
  } catch (error) {
    rejected = true;
  }
  if (!rejected) {
    throw new Error(`unsafe archive path was accepted: ${JSON.stringify(value)}`);
  }
}

equal(safe_archive_path('file.txt'), 'file.txt');
equal(safe_archive_path('one/two/file.txt'), 'one/two/file.txt');
equal(safe_archive_path('one/two/'), 'one/two/');
equal(safe_archive_path('one\\two\\file.txt'), 'one/two/file.txt');

for (const value of [
  '/absolute/file.txt',
  '../escape.txt',
  'one/../escape.txt',
  './file.txt',
  'one//file.txt',
  'C:/windows/file.txt'
]) {
  rejects(value);
}

console.log('Apps Script archive path contract passes');
