# Storage backend notes

These notes are exploratory. They are not an API contract.

The important distinction is that these systems do not all implement the same storage model. `cloud-storage-api` should avoid pretending that a synchronized directory, an object store, a content-addressed network, a federated file service, and a distributed filesystem are interchangeable.

## Storage models

| System | Primary model | Natural API shape | Important mismatch with Google Drive |
| --- | --- | --- | --- |
| Garage | distributed object storage | S3-compatible buckets, keys, objects | no native Drive-style file/folder hierarchy |
| Syncthing | peer-to-peer directory synchronization | folders, devices, indexes, blocks | synchronization system, not a canonical remote filesystem |
| IPFS + IPFS Cluster | content-addressed peer-to-peer storage | CIDs, DAGs, pins, replication | identity is content-derived; mutation is a separate problem |
| Tahoe-LAFS | capability-based decentralized storage | read/write capabilities over distributed shares | authority is capability-oriented rather than account/path-oriented |
| Nextcloud federation | federated hosted files and shares | files, directories, users, shares | federation joins servers at the sharing layer rather than merging their disks |
| Ceph | distributed storage substrate | object, block, and POSIX filesystem interfaces | much broader and lower-level than a Drive-like service |

## Garage

Garage is a lightweight, geo-distributed object store designed for small-to-medium self-hosted deployments. It implements the Amazon S3 object protocol and can replicate data across several machines or locations.

This is especially interesting for a private cloud assembled from heterogeneous machines because the application-facing interface can remain S3-like while the physical storage is owned and operated locally.

Possible shape:

```text
cloud-storage-api
      |
   S3 adapter
      |
    Garage
   /  |  \
 box box box
```

Implications for this repository:

- Garage would make a useful non-corporate object-storage backend.
- It tests whether the common API has accidentally inherited Google Drive's directory semantics.
- The common layer should not require a true folder tree for an object backend. Prefixes may be presented as folders by an adapter, but that is presentation rather than native structure.
- S3 compatibility gives a possible family boundary: one S3-oriented adapter could potentially support Garage and other S3-compatible stores without claiming identical behavior.
- Replication policy, placement, and cluster administration should remain backend-specific rather than being forced into ordinary file operations.

Reference: <https://garagehq.deuxfleurs.fr/>

## Syncthing

Syncthing is a peer-to-peer synchronization system. Devices exchange file metadata and blocks and attempt to bring configured folders into a common state. Its Block Exchange Protocol describes files in hashed blocks and tracks versions across participating devices.

This is not simply a self-hosted Dropbox server. There need not be one authoritative server-side copy at all.

Implications for this repository:

- Treat Syncthing primarily as a synchronization backend or transport, not as an ordinary remote object store.
- A useful abstraction may need to distinguish `synchronize` from `upload` and `download`.
- Device identity and folder identity matter in addition to paths.
- Conflict and version semantics belong to the backend rather than being flattened into a single last-writer-wins assumption.
- Block exchange is conceptually close to the desired peer-to-peer direction, but Syncthing does not use the BitTorrent protocol itself.

References:

- <https://syncthing.net/>
- <https://docs.syncthing.net/specs/bep-v1.html>

## IPFS and IPFS Cluster

IPFS is content-addressed. Stored content is identified by a CID derived from the content rather than by a mutable pathname. Peers exchange content over a peer-to-peer network.

IPFS Cluster adds distributed orchestration across multiple IPFS daemons. It maintains a replicated global pin set and controls which peers retain which content.

This is the strongest test in this list for whether `cloud-storage-api` can represent something other than a remote disk with paths.

Implications for this repository:

- CIDs should be preserved as first-class backend identifiers rather than hidden behind invented mutable paths.
- `store content` and `name content` should be separable operations.
- Persistence is explicit: pinning and replication are meaningful operations.
- A private IPFS network is relevant for storage spread across machines under common control. Only authorized nodes participate in that network.
- IPFS Cluster has its own private peer network for cluster coordination; this is distinct from whether the underlying IPFS daemons participate in the public IPFS network or a private IPFS network.
- Public-IPFS assumptions should not be silently used for personal/private storage. Privacy, encryption, discovery, and persistence need explicit policy.

References:

- <https://docs.ipfs.tech/>
- <https://docs.ipfs.tech/install/server-infrastructure/>
- <https://ipfscluster.io/documentation/>

## Tahoe-LAFS

Tahoe-LAFS is the Least-Authority File Store, a free and open decentralized storage system. It distributes data across multiple storage servers and is designed so that the file store can continue operating when some servers are unavailable or compromised.

Its security model is particularly interesting because access is capability-oriented rather than merely account-oriented.

Implications for this repository:

- Do not assume that every backend identifies authority as `account + path`.
- Read and write authority may themselves be values worth preserving.
- Tahoe-LAFS is useful as a design test for least-authority access and distributed failure tolerance.
- It is closer to a real distributed storage system than a simple directory synchronizer.
- If a future common API includes sharing, capabilities should be considered independently from provider-style ACLs.

Reference: <https://www.tahoe-lafs.org/trac/tahoe-lafs>

## Nextcloud federation

Nextcloud provides a conventional hosted-file model but can federate shares between independent Nextcloud servers. A user on one server can share files or directories with a user on another, creating a network of separately administered Nextcloud instances.

This is useful because it is federation in a fairly ordinary file/user model rather than content-addressed or cluster-level storage.

Implications for this repository:

- Nextcloud is a good example of a Drive-like backend that is still independently hostable.
- Federation should be modeled as sharing between administrative domains, not as though all participating servers form one physical filesystem.
- User identity, remote server identity, and share identity matter.
- Nextcloud's ordinary file APIs and its federation/share APIs should probably remain distinct backend capabilities.

References:

- <https://docs.nextcloud.com/server/stable/admin_manual/configuration_files/federated_cloud_sharing_configuration.html>
- <https://docs.nextcloud.com/server/stable/developer_manual/client_apis/OCS/ocs-share-api.html>

## Ceph

Ceph is a general distributed-storage system built around RADOS. It can expose object storage, block devices, and a POSIX filesystem. Its object gateway provides S3-compatible storage; RBD provides distributed block devices; CephFS provides a distributed filesystem.

Ceph is therefore less a single `cloud drive` backend than a storage substrate with several possible interfaces.

Implications for this repository:

- If used here, Ceph RGW is the most natural cloud-storage boundary because it exposes object storage and S3 compatibility.
- CephFS and RBD should not be silently treated as the same API merely because the same Ceph cluster can provide them.
- Ceph is useful as a stress test for keeping storage *interface* separate from storage *implementation*.
- It is much heavier operationally than the small private-cloud systems considered above, but it demonstrates how one distributed substrate can expose several incompatible storage abstractions.

Reference: <https://ceph.io/en/discover/technology/>

## BitTorrent itself

BitTorrent is primarily a distribution protocol for content described by torrent metadata. It is very good at peer-assisted transfer of immutable or versioned content, but by itself it does not supply the whole storage service needed here: mutable naming, authorization, persistence policy, deletion, directory semantics, and replication policy all need another layer.

The useful lesson is not necessarily to force BitTorrent itself underneath the API. It is to preserve concepts that peer-to-peer systems make explicit:

- content identity can be independent of location;
- more than one peer may provide the same content;
- retrieval need not have one authoritative server;
- persistence and replication are policies rather than automatic consequences of an upload;
- naming/mutation can be a separate layer over immutable content.

Syncthing and IPFS both share some of this block-oriented peer-to-peer character without being BitTorrent implementations.

## API design consequences

The common API should probably have a small capability model instead of claiming all backends support one large Drive-shaped interface.

Candidate capability families:

```text
hierarchical files
object storage
content-addressed storage
synchronization
sharing / federation
pinning / replication
version history
capability-based access
```

A backend can implement one or more families. Operations that do not have honest semantics for a backend should remain unsupported rather than being emulated invisibly.

One useful architectural direction is therefore:

```text
                    cloud-storage-api
                           |
          +----------------+----------------+
          |                |                |
     hierarchical       objects        content-addressed
          |                |                |
   Google Drive        Garage/S3         IPFS
   Nextcloud           Ceph RGW       IPFS Cluster
          |
       sharing
          |
    federation

   synchronization                capability storage
          |                               |
      Syncthing                       Tahoe-LAFS
```

This keeps `cloud-storage-api` from becoming merely a renamed Google Drive wrapper while still allowing the first implementation work to begin with Google Drive.
