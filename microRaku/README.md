# microRaku

**microRaku** is an experimental persistent `/usr` OverlayFS layer for **openSUSE MicroOS**.

It borrows the useful idea from RakuOS—keep the immutable base untouched and put native user packages in a persistent upper layer—but adapts it to MicroOS' Btrfs snapshot and `transactional-update` model.

> Status: **v0.1 experimental**. Use only on disposable or recoverable MicroOS systems until the update/rollback test matrix is complete.

## What v0.1 does

- keeps the MicroOS snapshot as the immutable lower `/usr`;
- mounts a persistent OverlayFS upper from `/var/lib/microraku/overlay/upper` during initrd `pre-pivot`;
- snapshots the lower RPM database before mounting the overlay;
- tracks only explicit user package requests in `packages.list`;
- rebuilds the upper layer when the MicroOS base snapshot changes or rolls back;
- keeps zypper metadata and downloaded RPMs in a private persistent cache under `/var/lib/microraku/cache`;
- records base-package overrides and rejects transactions that replace critical base components;
- detects and logs `/etc` drift caused by RPM transactions;
- performs remove/reset as clean rebuilds on the next boot instead of deleting the mounted upper live.

## Repository layout

```text
microraku/
├── README.md
├── LICENSE
├── SPEC.md
├── .gitignore
├── CONTRIBUTING.md
└── microraku/
    ├── install.sh
    ├── GUIDE.md
    ├── ARCHITECTURE.md
    ├── dracut/
    │   ├── module-setup.sh
    │   └── mount-overlay.sh
    ├── lib/
    │   └── sync.sh
    ├── systemd/
    │   └── microraku-sync.service
    └── bin/
        ├── microraku-install
        ├── microraku-list
        ├── microraku-remove
        └── microraku-reset
```

## Installation

Read `microraku/GUIDE.md` first.

```bash
cd microraku
sudo ./install.sh
sudo reboot
```

After reboot:

```bash
findmnt /usr
sudo microraku-install htop
microraku-list
```

## Design rule

microRaku does **not** own the MicroOS base. `transactional-update` remains authoritative for the base snapshot. microRaku owns only its persistent state in `/var/lib/microraku` and the OverlayFS upper layer.

Do not use `transactional-update apply` as a substitute for reboot while microRaku is active: it can replace the running `/usr` mount view. Stage normal MicroOS updates, then reboot into the new snapshot so the initrd can rebuild the overlay against the correct lower.

## Important limitation

OverlayFS only captures `/usr`. RPM scriptlets may still alter `/etc`, `/var`, users/groups, initrd or boot state. v0.1 detects `/etc` drift but cannot automatically undo arbitrary side effects outside `/usr`.

See `SPEC.md` and `microraku/ARCHITECTURE.md` for the full model.

## License

GPL-3.0-or-later.
