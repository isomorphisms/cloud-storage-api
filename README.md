# cloud-storage-api

Drive common cloud storage operations from the shell.

The first documented backend is Google Drive API v3. Keep the upstream API contract, our notes, and later executable code separate:

- `vendor/google-drive/drive.v3.json` — generated exact mirror of the pinned Google Drive v3 discovery document.
- `vendor/google-drive/UPSTREAM` — provenance and exact upstream pin.
- `docs/google-drive-api-notes.md` — project notes and implementation implications; commentary, not the contract.
- `AGENTS.md` — repository instructions and evidence boundaries.

The repository begins with the API boundary before choosing a larger implementation architecture.
