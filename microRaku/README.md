# microRaku

**microRaku** is an experimental persistent `/usr` OverlayFS layer for **openSUSE MicroOS**.

The project borrows the useful idea from RakuOS—keep the immutable base untouched and put native user packages in a persistent upper layer—but adapts it to MicroOS' Btrfs snapshot and `transactional-update` model.

> Status: **v0.1 experimental**. This repository is intended for controlled testing on disposable or recoverable MicroOS systems. It is not production-ready.

## Scope of v0.1

- openSUSE MicroOS only.
- `/usr` is the OverlayFS mount point.
- `/var/lib/microraku` stores persistent state.
- the lower RPM database is snapshotted before the overlay is mounted.
- when the MicroOS base changes, the overlay is rebuilt from the desired package list instead of carrying stale files over blindly.
- reset is deferred to the next boot; the live upper layer is never deleted in place.

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

Read `microraku/GUIDE.md` first. On MicroOS, `install.sh` stages its files under `/var` and uses `transactional-update run` when the running root is read-only.

```bash
cd microraku
sudo ./install.sh
sudo reboot
```

After reboot:

```bash
sudo microraku-install htop
microraku-list
```

## Design rule

microRaku does **not** own the MicroOS base. `transactional-update` remains the only mechanism that updates the base snapshot. microRaku owns only its state under `/var/lib/microraku` and the persistent OverlayFS upper layer.

See `SPEC.md` and `microraku/ARCHITECTURE.md` for details.

## License

GPL-3.0-or-later.
