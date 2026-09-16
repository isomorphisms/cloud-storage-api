---
schema_version: 1
kind: api_review_notes
subject: Google Drive API v3
verified_date: 2026-09-16
upstream_repository: googleapis/google-api-python-client
upstream_commit: 8e4ffe5ed7a0520fc67374d8c4a0d93571a27fc4
normative_spec: vendor/google-drive/drive.v3.json
source_pin: vendor/google-drive/UPSTREAM
interface_direction: shell-first
---

# Google Drive API v3 notes

These notes are a machine-oriented second pass over the Google Drive API v3 surface. They are commentary, not the API contract. When these notes disagree with `vendor/google-drive/drive.v3.json`, the mirrored discovery document wins.

## Source boundary

- The normative local API-shape source is `vendor/google-drive/drive.v3.json`.
- The mirror is pinned to the Google-maintained `googleapis/google-api-python-client` discovery artifact at commit `8e4ffe5ed7a0520fc67374d8c4a0d93571a27fc4` and Git blob `0434def28714b85a44c15938f744915e3088faed`.
- `vendor/google-drive/UPSTREAM` also records the live discovery endpoint and the human-facing REST reference.
- The mirrored discovery document describes methods, HTTP paths, parameters, OAuth scopes, request/response schemas, upload behavior, and resource types. It is generated upstream; never edit it by hand.
- The upstream artifact is covered by the accompanying Apache-2.0 license mirrored into `vendor/google-drive/LICENSE`.
- Current behavior can move after the pin. If a task depends on a new or changed API field, update the pin and mirror before changing implementation assumptions.

## Current top-level REST surface

The pinned v3 discovery surface contains these resource families:

- `about`
- `accessproposals`
- `approvals`
- `apps`
- `changes`
- `channels`
- `comments`
- `drives`
- `files`
- `operations`
- `permissions`
- `replies`
- `revisions`

The specification, not this list, is exhaustive for method parameters and schemas.

## The central object is a file ID, not a path

Drive is not a remote POSIX filesystem.

- Files, folders, shortcuts, and Google Workspace-native documents are represented through the `files` resource.
- Stable API operations are centered on opaque file IDs.
- A folder is a file with the Google Drive folder MIME type.
- A file has at most one parent in current v3 semantics, but the visible hierarchy is still metadata, not a path-based identity scheme.
- Shortcuts are distinct objects and can point at other Drive items.
- Shared drives add another scope boundary and different ownership/capability behavior.

A shell frontend may offer path-like convenience, but internal state should retain provider IDs and should not make reconstructed paths the only identity.

## Blob files versus Google Workspace-native documents

Do not collapse all content retrieval into one operation.

- Ordinary stored binary content can be retrieved as media through the file-content download surface described by the specification.
- Google Docs, Sheets, Slides, and other Workspace-native documents generally require export to a chosen MIME type rather than byte-for-byte download of a stored local file.
- Export formats and available MIME types are provider behavior and should remain visible at the provider boundary.
- Metadata retrieval should remain separate from content retrieval so a listing operation does not accidentally download bodies.

A generic cloud-storage layer therefore needs at least a distinction between `download stored bytes` and `export provider-native document`.

## ZIP and archive extraction

The current Drive v3 discovery surface contains no server-side `unzip`, `extract archive`, or equivalent method.

For a ZIP stored in Drive, extraction is therefore a client-side workflow unless another product-specific service is introduced:

1. identify the archive by file ID;
2. download the ZIP bytes;
3. read the archive locally or in a controlled worker;
4. create the destination folder hierarchy in Drive;
5. upload each extracted member;
6. record successful uploads before considering deletion of the source archive or local temporary data.

Do not represent that sequence as one atomic Drive operation. Partial failure is possible and needs explicit receipts/restart behavior.

For large archives, avoid requiring enough RAM for the whole archive plus all extracted members. Prefer streaming or bounded temporary storage where the ZIP format and chosen extraction library permit it.

## Upload boundary

Drive supports content upload in addition to metadata-only file creation/update.

- Small content can use the simpler upload forms.
- Multipart requests can combine metadata and content.
- Resumable upload is the important path for large files or unreliable connections.
- Upload state should be restartable where practical rather than forcing a complete restart after interruption.
- Do not hide provider upload-session identifiers if they are needed to resume work safely.

A shell command that says `put` or `copy in` can choose an upload strategy from size/network policy, but the receipt should still say what was actually exercised.

## Listing, search, and partial responses

`files.list` is more than a directory listing.

- Query expressions can filter Drive metadata.
- `spaces`, `corpora`, and shared-drive parameters affect the search universe.
- Results are paginated.
- The `fields` parameter controls partial responses and is important for both latency and quota/response size.
- A provider-neutral command should not silently assume that `list` means immediate children of a reconstructed path.

Keep the raw provider query capability available even if a smaller common query language is later added.

## Change tracking and synchronization

The `changes` resource is the natural incremental synchronization boundary.

- Obtain a starting page token.
- Replay change pages from a saved token.
- Persist the next/new start token only after the corresponding local state transition is durable.
- Shared-drive change logs and user change logs are distinct scopes that must not be conflated.
- A change entry represents current state for a changed item, not necessarily a field-level diff.

For a local mirror, treat the page token as protocol state. It is not a substitute for durable local item state.

## Revisions are not the same thing as changes

- `changes` is a synchronization/event feed.
- `revisions` addresses historical content versions for a file.
- Metadata changes and content revisions do not have identical semantics.
- Retention behavior differs by content type and provider policy.

A generic `version` abstraction should not be invented until another provider has been compared carefully enough to show which semantics are actually common.

## Permissions and capabilities

Drive permissions are object-level provider state, not ordinary Unix mode bits.

- Permission resources can refer to users, groups, domains, or broad link/world access depending on type and policy.
- Roles such as owner, organizer, file organizer, writer, commenter, and reader have Drive-specific meaning.
- Shared-drive permission inheritance and capabilities matter.
- The API exposes capabilities on resources; checking a capability can be safer than assuming an operation is allowed solely from a nominal role.
- Permission mutations on the same item should be serialized rather than treated as conflict-free independent writes.

Do not flatten this to `rwx` or a single public/private boolean.

## Authentication boundary

Private Drive data requires OAuth-authorized access.

- The discovery document enumerates supported Drive OAuth scopes.
- Use the least-privileged scope that satisfies the actual command set.
- `drive.file` is materially narrower than broad full-Drive access and is worth considering for commands intended to operate only on files selected/created through the application.
- Broad Drive scopes should not be requested merely because they simplify implementation.
- Credentials, refresh tokens, authorization codes, and bearer tokens never belong in source, fixtures, logs, receipts, or mirrored documentation.
- Do not bake a reusable shared OAuth client secret or user token into a distributable binary.

The exact installed-app/device/browser authorization flow is an implementation decision and should be documented separately once chosen.

## Shared drives

Shared drives are not just folders with a different root name.

- They have their own IDs and membership/role model.
- Several methods require explicit `supportsAllDrives`/shared-drive-aware parameters or a drive/corpus selection.
- Ownership semantics differ from My Drive.
- Domain administrator behavior is a separate privilege path.

Provider code should carry shared-drive context explicitly rather than hoping an ordinary My Drive call happens to work.

## Error and retry policy

The discovery document defines API shape, not a complete operational retry policy.

For implementation:

- distinguish authentication/authorization failures from retryable transport/server failures;
- use bounded exponential backoff for retryable requests;
- preserve resumable-upload state across retries where supported;
- do not blindly retry destructive or non-idempotent operations without understanding their request semantics;
- record the provider request/object identifiers needed to reconcile an uncertain outcome.

Do not hard-code quota numbers from memory. Quotas and product policies can change independently of the structural API specification.

## Generic cloud-storage abstraction: preserve differences first

This repository name is broader than Google Drive, but the first backend should not force every Drive concept into a premature least-common-denominator interface.

A useful provider-neutral record will probably need to preserve at least:

- provider name;
- account/authority identity;
- provider object ID;
- optional parent provider ID;
- object kind: stored blob, folder/container, provider-native document, shortcut/link, or other;
- display name;
- MIME/content type when meaningful;
- size when meaningful;
- content checksum when supplied;
- modification time and provider revision/version identifiers when supplied;
- shared-drive/container scope when supplied;
- permissions/capabilities as provider-specific attached state;
- synchronization/change cursor state separately from object state.

Do not decide that all providers have paths, revisions, checksums, export formats, or identical permission models. Preserve provider facts first; derive common conveniences second.

## Shell interface implications

The shell surface should compose cleanly through stdin/stdout without making terminal formatting the data model.

Likely command categories, without fixing names yet:

- authenticate / inspect account;
- list/search metadata;
- get metadata;
- download stored bytes;
- export provider-native content;
- upload/create/update content;
- create folder/container;
- move/reparent;
- copy;
- trash/delete/restore where supported;
- inspect/change permissions;
- inspect revisions;
- consume changes;
- archive extraction as a higher-level client workflow, not a primitive Drive API call.

Machine-readable output should be available separately from human-readable terminal presentation. Provider IDs must be representable without truncation.

## Things deliberately not decided yet

- Final command names and argument grammar.
- Whether the first executable implementation is Grease, Idriç, or a smaller bootstrap shell plus later typed components.
- Credential storage implementation.
- Local metadata/index database choice.
- Whether a local content cache is mandatory or optional.
- Generic provider interface shape beyond facts already forced by the Drive boundary.
- Conflict policy for two-way synchronization.
- Exact large-archive extraction staging policy.
- Additional providers and the order in which they are added.

## Machine-reading rules

- Treat `vendor/google-drive/drive.v3.json` as normative for the pinned Google Drive v3 API shape.
- Treat this file as commentary and extracted implementation constraints.
- Treat `vendor/google-drive/UPSTREAM` as the provenance record.
- Preserve unresolved items as unresolved rather than inventing defaults.
- If current upstream behavior matters, update the mirror pin before claiming the old snapshot is current.
- Never hand-edit generated vendor files.
