# microRaku architecture

## Why this is not just an OverlayFS mount

The persistent upper layer is the easy part. The difficult part is keeping package state coherent when the immutable MicroOS lower snapshot changes.

microRaku therefore separates three states:

```text
MicroOS snapshot (lower)      /usr + lower RPM DB
             +
microRaku upper               user package files + merged RPM DB copy-ups
             +
Desired state                 /var/lib/microraku/packages.list
```

## Runtime view

```text
                   /usr (merged)
                        ▲
                        │ OverlayFS
             ┌──────────┴──────────┐
             │                     │
 persistent upper (RW)       MicroOS /usr (RO)
 /var/lib/microraku/         current Btrfs snapshot
 overlay/upper
```

The RPM database is under `/usr/lib/sysimage/rpm`, so once `/usr` is overlaid, RPM/zypper writes are naturally captured by the upper layer. Before that mount, the dracut hook copies the lower database to `base-rpmdb`; this gives microRaku an immutable reference for answering “does the MicroOS base provide this package?” without confusing it with the merged view.

## Base identity

The initrd uses the root mount's Btrfs `FSROOT` as the base identity. A new transactional snapshot or a rollback changes that identity. Since the MicroOS lower is read-only, equal identity means equal lower filesystem for the purposes of v0.1.

## Reconciliation strategy

RakuOS contains sophisticated logic to merge package databases and hand individual packages back to a new image. microRaku v0.1 deliberately chooses a simpler MicroOS-first strategy:

1. detect a changed lower snapshot;
2. preserve one copy of the previous upper;
3. start a fresh upper;
4. boot the clean new base plus empty upper;
5. resolve `packages.list` again with zypper against that base;
6. delete the previous upper only after success.

This trades bandwidth and boot-time reconciliation work for easier correctness and rollback behavior during the prototype stage.

## Why removals are rebooted

Removing a package live from an OverlayFS merged tree can create whiteouts. If the same path is supplied by the immutable lower, a whiteout can hide a valid base file. v0.1 therefore changes desired state and rebuilds a clean upper on the next boot.

## Relationship with transactional-update

`transactional-update` remains authoritative for the base. The installer itself is staged transactionally so the dracut module, service and CLI tools become part of a MicroOS snapshot. The user package layer stays in `/var`, which is outside the root snapshot and survives base updates/rollbacks.

## Failure behavior

Early boot must be fail-safe. microRaku never makes the base unbootable merely because the overlay cannot be prepared. Any prerequisite failure causes the hook to return successfully without mounting the overlay; the machine continues with its normal MicroOS `/usr`.
