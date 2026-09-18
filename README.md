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


## Large ZIP range inventory

`commands/google-drive-zip-inventory.grease` inventories classic ZIP and
ordinary single-disk ZIP64 archives stored in Drive without downloading the
complete archive. It first gets Drive metadata, then performs bounded byte-range
reads:

1. at most 65,577 bytes from the archive tail, covering the classic
   end-of-central-directory record, maximum classic comment, and the 20-byte
   ZIP64 locator when present;
2. for ZIP64 only, exactly the 56-byte fixed ZIP64 end-of-central-directory
   record identified by the locator;
3. exactly the central-directory byte range named by the validated classic or
   ZIP64 end record.

The command requires HTTP 206 and an exact `Content-Range` matching the
requested interval and Drive's metadata size. Each curl transfer also has a hard
maximum response size, so a server that ignores `Range` cannot quietly turn an
inventory request into a full-archive download. The command requires curl 8.4
or newer because earlier curl releases did not enforce `--max-filesize` as a
running-transfer limit when the response size was not known up front.

`commands/zip-central-directory.c` is deliberately narrower than a ZIP
library. Grease owns Drive identity, authentication, metadata, and ranged
transport; the C helper only parses already-bounded local binary slices and
performs fixed-width ZIP/ZIP64 offset arithmetic. ZIP64 member values are read
from extra field `0x0001` only when the corresponding classic field contains
its ZIP64 sentinel, in the ordering defined by the ZIP format. This keeps
NUL-containing binary records and multi-gigabyte offsets out of shell variables,
including on ARMv7.

Inventory output is NDJSON: one archive record followed by selected member
records. `--exact`, `--prefix`, and `--glob` select members after the complete
central directory has been validated. The current boundary accepts stored and
deflate members, caps a central directory at 64 MiB and one million entries, and
rejects multi-disk archives, encryption, malformed ZIP64 metadata, ZIP64
features newer than version 4.5, unsupported compression methods, unsafe member
paths, and duplicate ambiguous member names.

Issue #7 keeps acceptance staged. The deterministic local fixture now covers
both classic ZIP and a sparse 5 GiB ZIP64 archive; the fake Drive HTTP Range
transport executed by the pinned Grease runtime covers both paths. These remain
stages 1 and 2 only. They are not evidence for authenticated Drive inventory,
live extraction, retry/resume, or the 7.75 GB Takeout archive; those remain
stages 3–7.

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
