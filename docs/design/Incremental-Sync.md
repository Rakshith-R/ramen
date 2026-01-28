<!--
SPDX-FileCopyrightText: The RamenDR authors
SPDX-License-Identifier: Apache-2.0
-->

# Incremental Sync for Consistency Groups

Extends [Cephfs-RDR-ConsistencyGroup.md](Cephfs-RDR-ConsistencyGroup.md).

## Summary

When `ramendr.openshift.io/enable-diff: "true"` is set on a DRPolicy
or VRG, Ramen preserves VolumeGroupSnapshots across sync cycles and uses
the [ceph-volsync-plugin](https://github.com/RamenDR/ceph-volsync-plugin)
External mover to transfer only changed blocks between consecutive snapshots.

## Annotation Propagation

```
DRPolicy → VRG → RGS (ReplicationGroupSource)
                → RGD (ReplicationGroupDestination)
```

Checked via `util.IsDiffSyncEnabled()`. Value must be exactly `"true"`.

## VolumeGroupSnapshot Lifecycle

Standard handler: single VGS with fixed name, deleted each cycle.

Diff handler: maintains two VGS via label `ramen.openshift.io/vgs-status`:

| Phase | Action |
|---|---|
| Create | New VGS named `{rgs-name}-{unix-timestamp}` with `status=current` |
| Cleanup | Prune old `previous` VGS → delete current's restored PVCs → transition `current` → `previous` |

At rest: exactly one VGS with `status=previous` serves as base for next cycle.

```
Cycle N:   [VGS-N: current] → sync → [VGS-N → previous]
Cycle N+1: [VGS-N+1: current] → diff(VGS-N, VGS-N+1) → [VGS-N deleted, VGS-N+1 → previous]
```

## External Spec vs RsyncTLS

Diff sync replaces the standard RsyncTLS ReplicationSource
spec with an External spec:

```go
rs.Spec.External = &ReplicationSourceExternalSpec{
    Provider: "cephfs.csi.ceph.com",
    Parameters: map[string]string{
        "copyMethod":         "Direct",
        "volumeName":         sourcePVCName,
        "baseSnapshotName":   previousSnapshotName,  // from previous VGS
        "targetSnapshotName": currentSnapshotName,    // from current VGS
        "address":            rdService,
        "secretKey":          volsyncPSKSecretName,
    },
}
```

ReplicationDestination similarly uses External with `copyMethod=Snapshot`.

The ceph-volsync-plugin mover compares `baseSnapshotName` and
`targetSnapshotName` at block level using CephFS snapshot diff APIs,
transferring only changed blocks. When `baseSnapshotName` is empty
(first cycle), it falls back to full sync.

## Handler Method Overrides

`diffVolumeGroupSourceHandler` embeds `volumeGroupSourceHandler` and
overrides four methods:

| Method | Standard | Diff |
|---|---|---|
| CreateOrUpdateVolumeGroupSnapshot | Fixed name, single VGS | Timestamp suffix, status labels |
| CleanVolumeGroupSnapshot | Deletes VGS + restored PVCs | Preserves previous, transitions current→previous |
| RestoreVolumesFromVolumeGroupSnapshot | Lookup by fixed name | Lookup by `status=current` label |
| CreateOrUpdateReplicationSourceForRestoredPVCs | RsyncTLS spec | External spec with base/target params |

All other methods inherited: `RestoreVolumesFromSnapshot`,
`CheckReplicationSourceForRestoredPVCsCompleted`, `WaitIfPVCTooNew`,
`EnsureApplicationPVCsMounted`.

## DR Operations

Transparent to failover/relocate. After failover, first sync on the
new primary is full (no previous base); subsequent syncs are incremental.

## Dependencies

* VolumeGroupSnapshot CSI
* ceph-volsync-plugin with External mover support
