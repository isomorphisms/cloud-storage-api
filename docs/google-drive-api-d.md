# Google Drive API in D

This is a parallel D implementation of the thin Google Drive v3 command. It is not a line-by-line translation of `commands/google-drive-api.grease`.

## Source of truth

The implementation is derived from the same provider contract as the rest of this repository:

- `vendor/google-drive/drive.v3.json` is the pinned normative discovery document.
- `commands/google-drive-v3-methods.tsv` is mechanically checked against that discovery document and is embedded into the D binary at compile time.
- Current Google documentation was re-read for request semantics that are not fully described by the method table, especially downloads, resumable uploads, and installed-application OAuth.

Relevant current documentation:

- Drive v3 REST reference: <https://developers.google.com/workspace/drive/api/reference/rest/v3>
- Download and export: <https://developers.google.com/workspace/drive/api/guides/manage-downloads>
- Upload file data: <https://developers.google.com/workspace/drive/api/guides/manage-uploads>
- Long-running downloads: <https://developers.google.com/workspace/drive/api/guides/long-running-operations>
- Installed-app OAuth: <https://developers.google.com/identity/protocols/oauth2/native-app>

The existing Grease implementation and tests are used as a compatibility checklist only. The D transport is implemented independently using `std.net.curl`.

## Boundary

`commands/google_drive_api.d` covers the generic `google-drive-api METHOD` surface:

- all 64 methods in the pinned discovery surface;
- named path parameters;
- repeated provider-native query parameters;
- raw JSON request bodies from a file or stdin;
- raw response bytes to stdout;
- `GOOGLE_ACCESS_TOKEN` / `GOOGLE_ACCESS_TOKEN_FILE` authentication without placing the token in process arguments;
- `X-Goog-Drive-Resource-Keys` when supplied;
- resumable media upload for `files.create` and `files.update`.

It deliberately does not fold Drive IDs into paths or combine stored-byte download, Workspace export, and long-running download operations.

The installed-app OAuth/refresh-token client from PR #10 remains a separate layer. This D command accepts an access token just as the generic thin API command does.

## Resumable upload difference

The D version follows Google's resumable-upload recovery protocol rather than merely retaining the session URI. When a saved session exists it:

1. sends an empty `PUT` with `Content-Range: bytes */TOTAL`;
2. accepts `200`/`201` as already complete;
3. on `308 Resume Incomplete`, reads the provider `Range` response and resumes at the next byte;
4. on `404`, starts a new resumable session;
5. retains the session record on transport interruption.

A saved session is bound to method, resolved API path, media path, MIME type, and byte size before reuse.

## Build

From the repository root:

```sh
ldc2 -O -release -Jcommands commands/google_drive_api.d \
  -of=build/google-drive-api-d -L-lcurl
```

The `-Jcommands` switch lets D embed `google-drive-v3-methods.tsv` at compile time, so the resulting executable has no runtime dependency on that table.
