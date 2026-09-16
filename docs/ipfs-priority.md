# IPFS priority

IPFS + IPFS Cluster is the first non-Google backend target for `cloud-storage-api`.

The point is not merely to add another provider. IPFS should force the common storage boundary to handle a model that is fundamentally unlike Google Drive:

- content-addressed identity through CIDs;
- peer-to-peer retrieval rather than one authoritative server;
- explicit pinning and replication policy;
- naming and mutation separated from immutable content;
- private-network operation for machines under common control;
- preservation of backend-native identifiers instead of inventing Drive-like paths.

Garage, Syncthing, Tahoe-LAFS, Nextcloud federation, and Ceph remain useful later backends and design tests, but IPFS should be implemented first among them.

The first IPFS work should distinguish the IPFS daemon API from IPFS Cluster orchestration. A local/private IPFS deployment must not be treated as equivalent to publishing data to the public IPFS network.
