# Historical reference — do not use for installation

These recovered files are not part of the active Agama path.

- `agama/post-install.sh.txt` hardcodes `kris`, deletes that user's password
  and enables PAM null passwords. It is preserved as text: do not execute it.
- `agama/workstation-partial-agama24.json` has an obsolete repository alias,
  an incomplete software list and an OEMDRV post-install reference.

Use `agama/profile-final.jsonnet` and `agama/tests/run-test02.sh` instead.
