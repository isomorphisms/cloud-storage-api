# cloud-storage-api

Drive common cloud storage operations from the shell.

The first documented backend is Google Drive API v3. Keep the upstream API contract, our notes, and later executable code separate:

- `vendor/google-drive/drive.v3.json` — generated exact mirror of the pinned Google Drive v3 discovery document.
- `vendor/google-drive/UPSTREAM` — provenance and exact upstream pin.
- `docs/google-drive-api-notes.md` — project notes and implementation implications; commentary, not the contract.
- `docs/storage-backends.md` — notes on non-corporate, self-hosted, federated, peer-to-peer, and distributed storage models and what they imply for the common API.
- `docs/ipfs-priority.md` — records IPFS + IPFS Cluster as the first non-Google backend target and the boundary it is meant to test.
- `AGENTS.md` — repository instructions and evidence boundaries.

After the Google Drive boundary, **IPFS + IPFS Cluster is the first non-Google backend target**. It should be implemented before Garage, Syncthing, Tahoe-LAFS, Nextcloud federation, or Ceph so the common API is forced early to support content-addressed identity, peer-to-peer retrieval, and explicit persistence/replication rather than quietly becoming a Drive-shaped abstraction.

The repository begins with the API boundary before choosing a larger implementation architecture.
