# Google-side ZIP extraction

`google-drive-unzip` extracts a ZIP that is already stored in Google Drive
without downloading the archive to the calling phone, tablet, or workstation.

There are two separate boundaries:

1. `commands/google-drive-unzip.ysh` is the Grease/YSH shell client.
2. `google-apps-script/unzip-drive.gs` is the Google-side worker.

Google Drive API v3 does **not** expose an archive-extraction endpoint. The
worker deliberately uses Apps Script `Utilities.unzip()` and Drive services
instead. The shell command invokes that worker through the public Apps Script
API `scripts.run` endpoint.

## One-time Google setup

Create an Apps Script project containing:

- `google-apps-script/unzip-drive.gs` as the script source;
- `google-apps-script/appsscript.json` as the manifest.

Associate the Apps Script project with a **standard Google Cloud project**,
enable the Google Apps Script API in that project, and create a versioned
**API Executable** deployment. The calling OAuth client must use that same
Google Cloud project.

Record the API Executable deployment ID outside Git:

```text
GOOGLE_APPS_SCRIPT_DEPLOYMENT_ID=...
```

The Apps Script API does not support service accounts for this execution path.

Official API references:

- https://developers.google.com/apps-script/api/reference/rest/v1/scripts/run
- https://developers.google.com/apps-script/api/how-tos/execute
- https://developers.google.com/apps-script/reference/utilities/utilities#unzipblob

## Authentication

The command accepts an OAuth access token either directly in the environment or
through a private token file:

```text
GOOGLE_ACCESS_TOKEN=...
```

or:

```text
GOOGLE_ACCESS_TOKEN_FILE=$HOME/.config/cloud-storage-api/google-access-token
```

The token must cover the scopes used by the deployed script. The checked-in
manifest currently requires full Drive access because this operation must read
an arbitrary existing ZIP and create files/folders beside it or in a named
destination. Do not put tokens, refresh tokens, client secrets, or authorization
codes in this repository.

The token is written only to a mode-0600 temporary curl configuration so it does
not appear in curl's argument vector.

## Run

The source may be a raw Drive file ID or a normal Drive sharing URL:

```text
google-drive-unzip DRIVE_ZIP
```

By default, the extracted folder is created beside the source ZIP. To choose a
different Drive folder:

```text
google-drive-unzip DRIVE_ZIP DESTINATION_FOLDER
```

Both arguments may be IDs or URLs.

stdout is one compact JSON object. Diagnostics go to stderr, so the result can
be piped to `jq` or another command.

## Extraction semantics

The worker:

- calls `Utilities.unzip()` inside Google's Apps Script runtime;
- preserves nested archive paths as Drive folders;
- rejects absolute paths, `..`, empty path components, and Windows drive-letter
  paths before writing anything at that member path;
- writes into a stable `<archive name> (extracted)` folder;
- reuses exactly matching files on a retry after comparing SHA-256 and byte
  length;
- errors rather than overwriting a conflicting existing file;
- errors if duplicate same-name Drive folders/files make a path ambiguous;
- appends a durable NDJSON receipt inside the output folder;
- never deletes the source ZIP.

This makes interrupted runs restartable without pretending the operation is
transactional.

## Evidence boundary

A syntax/static check of the client or Apps Script source proves only source
shape. A successful `scripts.run` request proves that the deployed executable
ran for the authenticated account. A complete extraction receipt proves only
the members recorded in that receipt. It does not prove unrelated Drive
operations or other target environments.

Apps Script executions have a bounded runtime (normally up to six minutes), and
`Utilities.unzip()` materializes archive members as blobs. This path is therefore
appropriate for ordinary Drive ZIPs, not an unlimited streaming archive service.
Large archives that exceed Apps Script runtime or memory limits need a different
server-side worker while preserving the same storage API boundary.
