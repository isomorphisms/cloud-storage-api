# cloud-storage-api

Drive common cloud storage operations from the shell.

The first documented backend is Google Drive API v3. Keep the upstream API
contract, our notes, higher-level provider workflows, and executable code
separate:

- `vendor/google-drive/drive.v3.json` — generated exact mirror of the pinned
  Google Drive v3 discovery document.
- `vendor/google-drive/UPSTREAM` — provenance and exact upstream pin.
- `docs/google-drive-api-notes.md` — project notes and implementation
  implications; commentary, not the contract.
- `docs/storage-backends.md` — notes on non-corporate, self-hosted, federated,
  peer-to-peer, and distributed storage models and what they imply for the
  common API.
- `docs/ipfs-priority.md` — records IPFS + IPFS Cluster as the first non-Google
  backend target and the boundary it is meant to test.
- `AGENTS.md` — repository instructions and evidence boundaries.

## Grease commands

`commands/google-drive-api.grease` is the complete thin Drive v3 command
surface. `commands/google-drive-v3-methods.tsv` has one row for every method in
the pinned discovery document. CI derives the same rows from the vendored JSON
and fails if a method is missing, extra, or has drifted in HTTP method, path,
request-body shape, media-upload capability, or deprecation state.

Examples:

```sh
google-drive-api files.list \
  --query 'q=trashed=false' \
  --query 'fields=nextPageToken,files(id,name,mimeType,thumbnailLink,thumbnailVersion)'

google-drive-api files.get \
  --path fileId=FILE_ID \
  --query 'fields=id,name,mimeType,modifiedTime,thumbnailLink,thumbnailVersion'

google-drive-api permissions.create \
  --path fileId=FILE_ID \
  --body permission.json

google-drive-api approvals.start \
  --path fileId=FILE_ID \
  --body approval.json
```

The leading `drive.` in a discovery method ID is optional. Query parameter names
and provider IDs remain Google Drive names; the command does not flatten them
into filesystem concepts.

Methods that advertise media upload use `--media FILE` plus a required
`--session-file FILE`. The command starts a resumable upload session, records
the session URI before transferring content, and retains that record on failure.
This keeps the large-upload boundary restartable rather than quietly treating a
large body as an ordinary request.

Authentication is supplied with `GOOGLE_ACCESS_TOKEN` or
`GOOGLE_ACCESS_TOKEN_FILE`. Tokens are placed in a private curl config rather
than curl argv. `GOOGLE_DRIVE_RESOURCE_KEYS` can supply the documented
`X-Goog-Drive-Resource-Keys` header when link-shared resources require it.

`commands/google-drive-files.grease` is the smaller convenience layer for the
reader-oriented operations already in use:

- `list` / search metadata;
- `get` metadata by opaque file ID;
- `download` stored bytes through `files.get?alt=media`;
- `export` Google Workspace-native content to an explicit MIME type.

Its list/get projection includes `hasThumbnail`, `thumbnailLink`,
`thumbnailVersion`, image metadata, and video metadata so a viewer can maintain
a local thumbnail cache without making those links part of durable identity.

`commands/google-drive-unzip.ysh` remains the separate Apps Script archive
workflow for now. It is not a Drive v3 endpoint: the Drive API itself has no
server-side unzip primitive.

## Provider boundary

Provider IDs remain first-class identity. Stored-byte download and Workspace
export stay distinct. Shared-drive scope, revisions, permissions, changes,
approvals, shortcuts, labels, resource keys, and deprecated Team Drive methods
remain visible rather than being forced through a pretend POSIX filesystem.

After the Google Drive boundary, **IPFS + IPFS Cluster is the first non-Google
backend target**. It should be implemented before Garage, Syncthing,
Tahoe-LAFS, Nextcloud federation, or Ceph so the common API is forced early to
support content-addressed identity, peer-to-peer retrieval, and explicit
persistence/replication rather than quietly becoming a Drive-shaped
abstraction.
