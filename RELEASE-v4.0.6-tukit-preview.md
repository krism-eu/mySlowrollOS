# mySlowrollOS atomic updater v4.0.6 — tukit preview

> **Status: design/validation preview. Not a production updater.**
>
> The tested operational baseline remains `myslowroll-atomic-dup-v3.4.9-tested.sh`.
> In this preview all mutating entry points are intentionally blocked until the
> v3.4.9 orchestration is fully rebased onto the tukit engine and the crash / recovery
> matrix has been exercised in a VM.

## What v4 changes

Version 4 moves the distribution upgrade away from an in-place `zypper dup` on the
live root. The intended model is:

1. keep the currently running Btrfs root as **SOURCE**;
2. create an offline read-write **TARGET** from SOURCE with `tukit open`;
3. run `zypper dup`, RPM manifests and post-update checks inside TARGET;
4. keep SOURCE untouched by RPM package changes;
5. make TARGET the default only after all verification barriers pass;
6. reboot and confirm the transaction only when the machine is actually running TARGET.

The ESP remains outside the root snapshot, so SOURCE and TARGET bootability are
verified independently. Aborting a TARGET cannot roll back writes already made to the
ESP.

## Current preview surface

Safe commands available now:

- `status` — inspect preview state;
- `check` — run preflight checks without creating a snapshot;
- `design` — print the intended transaction and recovery flow.

Intentionally blocked in this preview:

- `plan`
- `upgrade`
- `recover`
- `confirm`
- `abort`
- `prune`

This means **v4.0.6-tukit-preview must not be used as the system's operational updater**.

## Safety barriers already represented in the preview

The preview includes or specifies the following fail-closed barriers:

- active and default Btrfs snapshots must agree before a transaction;
- active SOURCE must be read-write and bootable;
- `/var`, state, cache and log storage must be demonstrably outside the root snapshot;
- RPMDB must be demonstrably inside the root snapshot;
- the transactional-update service/timer must not race the operation;
- existing ZYpp activity is rejected;
- the ESP must be mounted read-write and have a configurable minimum free-space margin;
- the `tukit` CLI surface is checked before use;
- SOURCE RPMDB is fingerprinted immediately after TARGET creation and checked again before update/commit;
- TARGET age is bounded by `MYSLOWROLL_TARGET_MAX_AGE_SECONDS` (default 3600 s);
- package cache visibility inside TARGET is checked before `zypper` starts;
- `zypper dup` is intended to run only inside TARGET under a host-side `systemd-inhibit` lock;
- expected and actual RPM manifests must match;
- critical packages and the Slowroll OS identity must be present in TARGET;
- SOURCE and TARGET must both remain bootable;
- recovery must never abort or delete an active TARGET;
- commit is rejected if SOURCE changed after TARGET was opened.

## Promotion criteria

The preview can be promoted to a release candidate only after all of the following are
completed:

1. rebase the complete, tested v3.4.9 planning/download/manifest orchestration onto the v4 engine;
2. implement the public `plan`, `upgrade`, `recover`, `confirm`, `abort` and `prune` command paths;
3. characterize the installed `tukit` version, `tukit.conf`, Snapper configuration and exact `open`/`close` behavior;
4. verify cache and ZYpp lock visibility with the actual `/run` sharing semantics;
5. inventory `/var` mounts and classify every persistent side effect;
6. verify that a TARGET receives a valid boot entry even when no kernel package changes;
7. test termination during `tukit call`;
8. test power loss during `tukit close`;
9. test spontaneous reboot from every `target-*` state and from `committing`;
10. verify recovery decisions for every `(active, default, TARGET, durable-state)` combination;
11. repeat a normal end-to-end upgrade, reboot and confirmation cycle in a disposable VM;
12. only then remove the preview namespace and version the operational script as a v4 RC/final.

## Operational baseline

Until those promotion criteria are satisfied, use:

```text
myslowroll-atomic-dup-v3.4.9-tested.sh
```

The v4 preview is published for code review, architecture review and controlled VM
validation only.
