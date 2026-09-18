# AGENTS.md

## Repository purpose

`cloud-storage-api` is a shell-first experiment for common cloud-storage operations. Google Drive API v3 is the first documented provider boundary. Do not pretend Google Drive is a POSIX filesystem, and do not erase provider-specific semantics merely to make an early generic interface look uniform.

## Read first

1. `vendor/google-drive/UPSTREAM` — exact upstream repository, commit, path, Git blob ids, and live reference URLs.
2. `vendor/google-drive/drive.v3.json` — exact mirrored Google Drive API v3 discovery document. This is the normative pinned API-shape source and is generated; never edit it by hand.
3. `docs/google-drive-api-notes.md` — machine-oriented review of the API and implementation implications. This is commentary, not the contract.
4. `.github/workflows/mirror-google-drive-discovery.yml` — mechanism that fetches and verifies the pinned upstream bytes.
5. `vendor/google-drive/LICENSE` — license accompanying the upstream discovery artifact.

If the notes and the discovery mirror disagree about an endpoint, parameter, scope, request, response, or schema, the pinned discovery document wins. If a task depends on current behavior newer than the pin, update the pin and mirror before rewriting implementation assumptions around an old snapshot.

## Source updates

- Do not hand-edit `vendor/google-drive/drive.v3.json`, `vendor/google-drive/drive.v3.json.sha256`, or `vendor/google-drive/LICENSE`.
- Change `vendor/google-drive/UPSTREAM` only to an intentional upstream commit with matching expected Git blob ids.
- Let `.github/workflows/mirror-google-drive-discovery.yml` fetch and verify the exact pinned files.
- After a source update, review `docs/google-drive-api-notes.md` for semantic drift.
- Preserve upstream provenance and license.
- Do not silently replace the pinned discovery document with a live unpinned fetch.

## API boundary

- Use documented Google Drive API surfaces.
- Keep opaque provider file IDs as first-class identity. Do not use reconstructed paths as the only identity.
- Preserve the distinction between stored-byte download and export of Google Workspace-native documents.
- Preserve shared-drive scope, revision identifiers, change-page tokens, permissions, capabilities, checksums, and provider-native object kinds when present.
- Do not flatten Drive permissions to Unix `rwx` or a public/private boolean.
- Do not assume folders are a separate storage primitive; in Drive they are file resources with a folder MIME type.
- Do not assume shortcuts are transparent aliases; preserve shortcut identity and target metadata.
- Do not claim the Drive API provides server-side ZIP extraction. The pinned v3 surface has no unzip/extract primitive; archive extraction is a higher-level workflow. The current Google-side ZIP implementation deliberately crosses into the documented Apps Script API and `Utilities.unzip()` rather than inventing a Drive v3 method.
- Keep credentials, OAuth codes, refresh tokens, access tokens, and secrets out of source, fixtures, logs, transcripts, receipts, and generated artifacts.

## Generic-provider discipline

This repository may add other storage providers later. Until there is real evidence from another provider:

- do not invent a lowest-common-denominator model and force Drive into it;
- keep provider-specific fields available behind any common interface;
- do not assume every provider has paths, revisions, change logs, export formats, checksums, shared drives, or the same permission model;
- derive conveniences from preserved provider facts rather than discarding facts to simplify the abstraction;
- distinguish provider object state from synchronization cursor/protocol state.

When a second provider arrives, compare semantics explicitly before promoting anything to the common layer.

## Shell boundary

The intended interface is shell-first and composable. The current executable command line is Grease/YSH.

- Keep product shell commands in Grease/YSH unless a later explicit design decision changes that boundary.
- Keep machine-readable output distinct from human terminal presentation.
- Prefer stdin/stdout composition where it makes sense.
- Never truncate provider IDs in machine output.
- Do not require a generated SDK or a large framework merely because it is convenient.
- Small POSIX `sh` in vendor/update automation and source-contract fixtures is infrastructure/compatibility scaffolding, not evidence that the product command executed under Grease.
- A `sh` or `dash` parse/run may catch portability regressions, but a Grease receipt must execute the current Grease/YSH implementation.

Whenever giving the human a script or command block, assume `$PWD` is arbitrary. Resolve repository and file paths from the script's own location, an explicit project location, or a discovered repository root, and perform any required `cd` inside the script. Never require the human to `cd` first or rely on relative paths against their current working directory.

## Download, upload, and archive handling

- Metadata listing must not accidentally fetch file bodies.
- Large uploads should preserve resumable-upload state when the provider supports it.
- Downloads and exports are different operations; keep that distinction visible.
- Archive extraction should be restartable and receipt-driven: record successfully created folders/files before considering source deletion.
- Avoid designs that require holding a complete large archive plus all extracted members in RAM.
- Do not delete the source archive as part of an extraction workflow until the intended destination state has been verified.


### Large ZIP ranged inventory

- Keep the existing Apps Script `Utilities.unzip()` path scoped to ordinary
  archives. Its source/compatibility receipts are never evidence for the
  large-archive ranged path.
- Grease owns provider identity, authentication, metadata, and HTTP Range
  orchestration. The small C ZIP helper owns binary structure parsing and
  64-bit archive-offset arithmetic only; it must not grow provider/network I/O.
- Inventory must not download the complete archive. Bound the tail read to the
  classic EOCD maximum, then fetch exactly the central-directory range.
- Require HTTP 206 and an exact `Content-Range` for every Drive range read.
  Keep a hard maximum response size so an ignored Range header cannot become a
  silent whole-file download. The current curl implementation requires 8.4 or
  newer because that is the boundary where `--max-filesize` gains an active
  running-transfer limit for responses whose size was not known up front.
- Do not do multi-gigabyte ZIP offset arithmetic in shell expressions; keep it
  in the fixed-width C boundary so ARMv7 does not become a hidden exception.
- Validate the complete central directory before writing a successful inventory
  to stdout. Reject unsafe paths, duplicate ambiguous names, encryption,
  unsupported compression, multi-disk archives, and ZIP64 until those cases
  have explicit implementations and tests.
- Keep issue #7 acceptance stages independent: (1) deterministic local range
  fixture, (2) fake Drive ranged transport under Grease, (3) live authenticated
  ranged inventory, (4) live bounded-member extraction, (5) live multi-member
  retry/resume, (6) 7.75 GB Takeout inventory without full client download, and
  (7) selected Takeout extraction. Never promote local/fake evidence into a
  later live stage.

## Synchronization

- Use Drive change-page tokens as protocol cursors, not as substitutes for durable local state.
- Persist a new cursor only after the local application of the corresponding change page is durable.
- Keep user change logs and shared-drive change logs distinct.
- Do not confuse `changes` with file `revisions`.
- For uncertain write outcomes, preserve enough provider/request identity to reconcile rather than blindly repeating destructive operations.

## Authentication

- Use least-privileged OAuth scopes that satisfy the actual command set.
- Do not broaden to full-Drive access merely to avoid designing a narrower flow.
- Do not embed reusable user credentials or shared secrets in binaries.
- Keep authentication architecture separate from the storage object model so it can change without rewriting object identity.

## Evidence and acceptance

- A green mirror workflow proves that the vendored bytes match the pinned upstream Git blobs. It does not prove authenticated Google Drive runtime behavior.
- Static inspection of the discovery document is API-shape evidence, not an end-to-end API receipt.
- The `Google Drive unzip contract` workflow proves source/compatibility properties only. It does not prove Grease execution, Apps Script deployment, OAuth, or a real Drive extraction.
- A successful metadata call is not evidence that upload, download, export, permissions, shared drives, changes, or archive workflows work.
- Acceptance claims must state the exact operation, provider account context, content type, and environment actually exercised.
- Never promote mock, local-only, POSIX-compatibility, or documentation evidence into live provider or Grease acceptance.

## Change discipline

- Keep upstream vendor material, our notes, implementation policy, and executable evidence visibly separate.
- Mark unresolved choices as unresolved instead of manufacturing a decision.
- Prefer small branches and reviewable changes.
- Claims about current API behavior should name the upstream pin or a dated official source.
- If source generation changes, keep the generated files reproducible from the provenance record.
