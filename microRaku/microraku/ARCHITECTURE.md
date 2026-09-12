# microRaku architecture

## Why this is not just an OverlayFS mount

The persistent upper layer is the easy part. The difficult part is keeping package state coherent when the immutable MicroOS lower snapshot changes.

microRaku therefore separates four states:

```text
MicroOS snapshot (lower)      /usr + lower RPM DB
             +
microRaku upper               user files + merged RPM DB copy-ups
             +
Desired state                 /var/lib/microraku/packages.list
             +
Persistent package cache      /var/lib/microraku/cache
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

The RPM database lives under `/usr/lib/sysimage/rpm`. Once `/usr` is overlaid, RPM/zypper writes are captured by the upper layer. Before that mount, the dracut hook copies the lower database to `base-rpmdb`; this gives microRaku a stable answer to “what does the current MicroOS base provide?” without confusing lower state with the merged view.

## Base identity

The initrd uses the root mount's Btrfs `FSROOT` as the base identity. A new transactional snapshot or rollback changes that identity. v0.1 treats an identity change as a mandatory clean reconstruction boundary.

## Reconciliation strategy

RakuOS contains sophisticated logic to merge package databases and hand individual packages back to a new image. microRaku v0.1 deliberately chooses a simpler MicroOS-first strategy:

1. detect a changed lower snapshot;
2. preserve one previous upper for recovery;
3. start a fresh upper;
4. mount the new base plus the empty upper;
5. resolve the desired package names again with zypper;
6. keep downloaded RPMs and libzypp metadata in a private persistent cache;
7. compare the resulting merged RPM DB with `base-rpmdb`;
8. reject critical base overrides;
9. delete `previous-upper` only after a successful reconciliation.

This trades bandwidth and boot-time work for easier correctness and rollback behavior during the prototype stage.

## Package cache

microRaku redirects both libzypp metadata and repository RPM downloads away from the normal `/var/cache/zypp` tree. The RPM cache is configured with `.keep_packages` and `.no_auto_prune`, so successful installs retain their packages. A later rebuild can therefore reuse the same artifacts when the relevant cached repository metadata still resolves them.

The cache is intentionally described as **best effort**. Tumbleweed/MicroOS repositories evolve; retaining RPM files does not by itself preserve every historical dependency graph.

## Base override tracking

After an install or rebuild, microRaku compares each package present in the saved lower RPM database against the merged RPM database. Differences are written to `state/modified-base.tsv`.

Overriding some base libraries may be necessary to satisfy a user package, but overriding package-management, transaction, boot or kernel-critical components defeats the intended safety boundary. Those critical overrides cause the transaction to be rejected and a clean rebuild to be scheduled.

## `/etc` drift tracking

OverlayFS protects only `/usr`. Package scriptlets can still change `/etc`. microRaku therefore fingerprints the `/etc` tree before and after zypper operations and records detected drift in `state/etc-drift.log`. v0.1 reports this condition; it does not attempt an automatic configuration rollback.

## Why removals are rebooted

Removing a package live from an OverlayFS merged tree can create whiteouts. If the same path is supplied by the immutable lower, a whiteout can hide a valid base file. v0.1 therefore changes desired state and reconstructs a clean upper at the next boot.

## Relationship with transactional-update

`transactional-update` remains authoritative for the base. The installer itself is staged transactionally so the dracut module, service and CLI tools become part of a MicroOS snapshot. The package layer stays in `/var`, outside the root snapshot.

The supported boundary is reboot. `transactional-update apply` can replace the live `/usr` view and is therefore intentionally outside the v0.1 test path.

## Failure behavior

Early boot is fail-safe. Package transactions are fail-closed with respect to desired state: if zypper fails or a critical base override is detected, the attempted request is not accepted as authoritative and a clean rebuild is scheduled.
