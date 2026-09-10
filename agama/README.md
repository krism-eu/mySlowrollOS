# Agama installation path

The first mySlowrollOS installer path deliberately reuses the official Agama Live ISO instead of rebuilding an installer ISO.

The project profile is intentionally partial:

- product: `Slowroll`;
- no desktop or distribution patterns (`patterns: []`);
- explicit packages generated from `experiments/rootfs/system.seed` plus `experiments/rootfs/plasma.seed`, exactly like the KIWI workstation description, plus `criscore1` and `criscore2`;
- `onlyRequired: true`;
- one OBS repository containing the criscore RPMs;
- localization preset to `it_IT.UTF-8`, keyboard `it` and timezone `Europe/Rome`;
- no `storage` section;
- no users or passwords.

Omitting storage and identity is deliberate. After loading the profile, storage, user account and passwords are completed manually in the Agama UI, including reuse of an existing `/home` without formatting. Filesystem choice also remains manual, so a small VM can use ext4 while the real workstation can use Btrfs with Snapper.

## Runtime policy

The generated `agama/workstation.jsonnet` embeds the contents of `agama/post-install.sh` as a chrooted post-installation script. Keeping the generated profile self-contained means the same single file works from GitHub or from `usb:///`.

The runtime policy deliberately remains small and reversible:

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

## Load from GitHub

During development the profile can be loaded from its raw GitHub URL. Running `agama config generate` first evaluates Jsonnet and then `agama config load` applies the partial configuration without starting the installation:

```sh
agama config generate PROFILE_URL > /tmp/myslowroll.json
agama config load < /tmp/myslowroll.json
```

Then continue in the graphical UI for storage, user and passwords.

## Load from USB

Copy just this generated file to the root of a USB filesystem:

```text
workstation.jsonnet
```

Agama can locate it on attached USB devices through its `usb:///` URL scheme:

```sh
agama config generate usb:///workstation.jsonnet > /tmp/myslowroll.json
agama config load < /tmp/myslowroll.json
```

Because the post-install policy is embedded in the generated Jsonnet profile, no companion script is required on the USB device.

Do not name the file `autoinst.jsonnet` on an `OEMDRV` filesystem unless fully unattended installation is desired. For this workstation the intended flow is to load the partial profile and then review the remaining choices in the GUI.

## Boot Agama

Use the official Agama Live ISO. The profile can also be supplied through `inst.auto` when appropriate, but for interactive workstation installation the tested and preferred workflow is to boot the normal installer, load the profile manually from GitHub or `usb:///`, and then finish storage and identity in the web UI.

The OBS repository key is intentionally not bypassed with `allowUnsigned`.

## ISO policy

A custom installer ISO is not required. If a single-medium installer becomes useful later, inject the same profile into an official Agama ISO instead of maintaining a fork of the installer image. Keep the profile under a non-special path/name if interactive review is desired rather than automatic unattended installation.
