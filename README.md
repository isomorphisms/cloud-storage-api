# cloud-storage-api

Drive common cloud storage operations from the shell.

The first documented backend is Google Drive API v3. Keep the upstream API
contract, our notes, higher-level provider workflows, and executable code
separate.

## Commands

- `commands/google-drive-unzip.ysh` — Grease/YSH client for Google-side ZIP
  extraction through a deployed Apps Script API executable. The ZIP stays in
  Drive; see `docs/google-drive-unzip.md`.

## Google Drive contract work

The Google Drive v3 discovery mirror is maintained separately from the command
implementation. The Drive API itself has no server-side unzip primitive; the
archive command intentionally crosses into the documented Apps Script API for
that higher-level operation.
