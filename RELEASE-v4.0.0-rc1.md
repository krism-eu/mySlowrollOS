# mySlowrollOS atomic updater v4.0.0-rc1

> **Release candidate for disposable-VM validation only.**
>
> The operational workstation baseline remains `myslowroll-atomic-dup-v3.4.9-tested.sh` until the RC1 matrix passes.

## What RC1 integrates

`myslowroll-atomic-dup-v4.0.0-rc1.sh` reuses the tested v3.4.9 planning engine instead of duplicating it. At load time it places the inherited planning/state helpers in a dedicated v4 RC1 namespace, leaving the v3 state, cache, logs and lock untouched.

The execution path is replaced with the tukit model:

1. create/revalidate the v3.4.9 plan and pre-download cache;
2. open an offline read-write TARGET from SOURCE with tukit;
3. fingerprint SOURCE immediately after TARGET creation;
4. run `zypper dup` only inside TARGET;
5. compare the TARGET RPM manifest with the plan's expected manifest;
6. verify critical packages, Slowroll identity and SOURCE/TARGET bootability;
7. close TARGET only after all barriers pass;
8. leave the transaction `pending-reboot`;
9. after a real reboot into TARGET, verify the manifest again and run `confirm`.

`upgrade`, `recover` and `abort` require the explicit VM-only opt-in:

```text
MYSLOWROLL_RC1_ENABLE_MUTATIONS=1
```

## First VM pass

Run these in order on a disposable VM with the v3.4.9 baseline file in the same directory as RC1:

```text
sudo ./myslowroll-atomic-dup-v4.0.0-rc1.sh check
sudo ./myslowroll-atomic-dup-v4.0.0-rc1.sh plan
sudo ./myslowroll-atomic-dup-v4.0.0-rc1.sh status
sudo env MYSLOWROLL_RC1_ENABLE_MUTATIONS=1 ./myslowroll-atomic-dup-v4.0.0-rc1.sh upgrade
sudo ./myslowroll-atomic-dup-v4.0.0-rc1.sh status
```

If `upgrade` reaches `pending-reboot`, reboot the VM manually and then run:

```text
sudo ./myslowroll-atomic-dup-v4.0.0-rc1.sh status
sudo ./myslowroll-atomic-dup-v4.0.0-rc1.sh confirm
sudo ./myslowroll-atomic-dup-v4.0.0-rc1.sh status
```

Do not proceed to fault injection until this normal cycle succeeds.

## Required observations

Record at minimum:

- `tukit --version`;
- effective `/etc/tukit.conf` and `/usr/etc/tukit.conf` configuration;
- SOURCE active/default snapshot numbers before `upgrade`;
- raw `tukit open` output;
- TARGET snapshot number and RW property before and after `tukit close`;
- visibility of the transaction package cache from `tukit call`;
- SOURCE and TARGET results from `sdbootutil is-bootable`;
- active/default snapshot after reboot;
- RC1 state and `v4-rc1.meta` before and after each transition.

## Fault matrix after the normal pass

Test on fresh VM clones:

1. terminate the process during `tukit call` / zypper;
2. terminate immediately after TARGET verification but before close;
3. simulate interruption during `tukit close`;
4. reboot while state is `prepared`;
5. reboot while state is `in-progress` / `target-updating`;
6. reboot while phase is `target-verifying`;
7. reboot while phase is `committing`;
8. test a `tukit open` result the parser cannot recognize;
9. modify SOURCE package state after TARGET open and verify commit is refused;
10. exceed `MYSLOWROLL_TARGET_MAX_AGE_SECONDS` and verify commit is refused.

For every case verify that RC1 never aborts an active/default TARGET and never modifies SOURCE RPM state as part of the offline dup.

## Promotion gate

RC1 must not replace v3.4.9 until the normal cycle and the crash/recovery matrix are documented as passing on the actual target Slowroll/tukit build.
