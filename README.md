# mySlowrollOS

Personal openSUSE Slowroll / Plasma Wayland workstation, installed interactively
with stock Agama 24.

## Active installation profile

Use `agama/profile-final.jsonnet`. Storage, username and credentials are chosen
in the Agama UI. Do not use unattended `inst.auto` on the real machine.

From a checkout/archive of a reviewed commit, run in the Agama live environment:

```sh
bash agama/tests/run-test02.sh
```

This validates and loads the **actual final profile**, downloads the pinned
scripts and compares them byte-for-byte with local tested copies before
checking syntax, then probes the installation proposal. It does not
start installation or prove that the installed system boots.

For direct remote loading, replace COMMIT with the full reviewed commit SHA:

```sh
agama config generate https://raw.githubusercontent.com/krism-eu/mySlowrollOS/COMMIT/agama/profile-final.jsonnet > /tmp/myslowroll.json
agama config validate /tmp/myslowroll.json
agama config load /tmp/myslowroll.json
```

Review all commands' results before proceeding in the UI.

## Sources and generated files

- Workstation package selection: `myslowroll-workstation/myslowroll-workstation.spec` (used as an install manifest; the metapackage RPM is not published on OBS).
- Packages installed only by Agama: `agama/install-only-packages.txt` (currently YaST GUI/modules).
- Protected core source: `core/protected.seed` and `obs/criscore1/criscore1.spec.in`.
- Generated OBS spec: `obs/criscore1/criscore1.spec` (one source builds both anchors).
- Profile structure, repository and file/script mapping: `agama/profile-policy.json`.
- Policy contents: `myslowroll-policy/` and the two active scripts in `agama/`.
- Immutable asset revision: `agama/assets-revision`.

Regenerate the anchor spec with `python3 core/generate-criscore-spec.py`;
verify using `python3 core/generate-criscore-spec.py --check`. For OBS, copy
the generated .spec, not the seed or template.

Generate profiles with `python3 agama/generate-profiles.py`; check for drift with
`python3 agama/generate-profiles.py --check`. Never edit generated profiles.
The check rejects overlap between install-only and persistent RPM requirements,
checks that the two criscore anchors agree, that the spec matches seed and
template, and that protected requirements are a subset of the workstation.
Agama requests the manifest's individual packages directly (159, including
Plymouth for the boot splash) plus eleven
install-only packages (ten YaST tools and xauth); it does NOT request an unpublished
`myslowroll-workstation` metapackage. The two criscore anchors continue to
protect the approved core; workstation extras are selected at installation
but not yet held by a workstation RPM on later updates.
JSON is valid Jsonnet; the profiles are self-contained and need no remote imports.
Only profile-final.jsonnet is generated. The Test 02 runner tests that same
final profile without maintaining a redundant copy.
Agama defaults to Italian locale `it_IT.UTF-8` and keyboard `it` (editable in
the installer); it does not force a timezone, disk layout or login credentials.
YaST is requested at installation but is intentionally not held in place by
RPM dependency anchors: if Slowroll later drops it, an existing workstation
will not block upgrades solely because of our own packages.

When changing policy contents/scripts, commit those assets first. Then run
`python3 agama/generate-profiles.py --assets-revision FULL_ASSET_COMMIT_SHA`
and commit the generated profile and revision file. Publish both commits
together. CI compares deployed policy/scripts/keys with the pinned commit,
and Test 02 compares the downloaded scripts byte-for-byte with local copies.
Changing local assets without updating the pin fails CI.

See `ARCHITECTURE.md` and `agama/tests/TEST-02.md`.
Historical files in `legacy/` are excluded from the active installation path.
