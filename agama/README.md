# Agama installation path

The first mySlowrollOS installer path deliberately reuses the official Agama Live ISO instead of rebuilding an installer ISO.

The project profile is intentionally partial:

- product: `Slowroll`;
- no desktop or distribution patterns (`patterns: []`);
- explicit packages generated from `experiments/rootfs/system.seed` plus `experiments/rootfs/plasma.seed`, exactly like the KIWI workstation description, plus `criscore1` and `criscore2`;
- `onlyRequired: true`;
- one OBS repository containing the criscore RPMs;
- no `storage` section;
- no users or passwords;
- no locale or keyboard choice imposed by the profile.

Omitting storage and identity is deliberate. The profile is loaded with `inst.install=0`, so Agama applies the software/product choices and then stops for review. Storage, user account, password, locale and keyboard are completed manually in the Agama UI, including reuse of an existing `/home` without formatting.

## Runtime policy

The profile runs `agama/post-install.sh` as a chrooted post-installation script. It deliberately keeps the policy small and reversible:

- sets `graphical.target` as the default target;
- disables `NetworkManager-wait-online.service`;
- disables `ModemManager.service` on this workstation with no WWAN modem;
- keeps journald enabled for diagnostics but caps persistent usage at 128 MiB, runtime usage at 64 MiB and retention at seven days;
- does not disable NetworkManager, firewalld, AppArmor, Bluetooth, CUPS/Avahi, Snapper or Btrfs maintenance.

The service policy is separate from the package protection policy: none of these runtime choices changes `protected.seed` or the criscore dependency graph.

## Generate the profile

The generator accepts either the OBS RPM-MD directory or the `.repo` URL printed by `osc repourls`. A `.repo` URL is normalized to its containing directory.

Current OBS source:

```text
https://download.opensuse.org/repositories/home:/krism/openSUSE_Slowroll/home:krism.repo
```

Generate with:

```sh
bash agama/generate-workstation-profile \
  https://download.opensuse.org/repositories/home:/krism/openSUSE_Slowroll/home:krism.repo
```

The generated `agama/workstation.jsonnet` uses:

```text
https://download.opensuse.org/repositories/home:/krism/openSUSE_Slowroll/
```

as `software.extraRepositories[].url`.

## Boot Agama

Use the official Agama Live ISO. During development prefer an immutable raw GitHub URL pinned to a commit, so the profile and the relative `post-install.sh` come from the same revision.

For the profile committed as `690cb54560d8a784ddc7ea400471919e753ba76e`:

```text
inst.auto=https://raw.githubusercontent.com/krism-eu/mySlowrollOS/690cb54560d8a784ddc7ea400471919e753ba76e/agama/workstation.jsonnet inst.install=0 inst.systemd_boot_preview=1 inst.remote=0
```

`inst.install=0` is mandatory for this project path: the machine must stop for review instead of immediately installing. `inst.systemd_boot_preview=1` enables Agama's current systemd-boot path for testing and installation testing must verify that Agama did not fall back to GRUB. `inst.remote=0` keeps the local installer UI from being exposed to other machines during this single-workstation installation.

The OBS repository key is intentionally not bypassed with `allowUnsigned`. If Agama asks about the OBS project key during the first test, review and trust the presented key interactively; after that test the accepted fingerprint can be pinned in the profile if useful.

## ISO policy

Do not build a custom ISO for the first installation tests. If the remote-profile flow is validated and an offline/single-medium installer becomes useful later, inject the same profile into an official Agama ISO instead of maintaining a fork of the installer image.
