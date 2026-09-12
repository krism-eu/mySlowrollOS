# Contributing to microRaku

microRaku is experimental low-level system software. Changes should favor recoverability and explicit behavior over cleverness.

## v0.1 rules

1. Target openSUSE MicroOS first. Do not add another distro backend until the MicroOS update/rollback cycle is demonstrably stable.
2. Never modify the immutable lower `/usr` from the running system.
3. Persistent state belongs under `/var/lib/microraku`.
4. Destructive upper-layer operations happen before the overlay mount, not against a live mounted upper.
5. A mount failure must degrade to a bootable clean base.
6. Package-manager state must distinguish the MicroOS lower RPM database from the merged microRaku view.
7. Every shell change must pass `bash -n` before commit. ShellCheck is recommended when available.

## Test scenarios

At minimum, changes to the core should be exercised through:

- fresh install and first boot;
- install a package not present in the base;
- reboot without a base update;
- MicroOS transactional update followed by reboot/reconciliation;
- rollback to the previous MicroOS snapshot;
- remove a tracked package and reboot;
- reset the overlay and reboot;
- boot with `microraku=0`;
- forced overlay-mount failure to confirm clean-base fallback.

Please include exact MicroOS snapshot/build information and relevant journal output in bug reports.
