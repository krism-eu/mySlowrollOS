# Agama safe test 01 — OBS repository, GPG and criscore

This test intentionally does **not** configure storage and does **not** start installation.

From a checkout/archive of the reviewed commit in an Agama live environment.
Authentication is left untouched; enter credentials in the UI if needed.

```bash
PROFILE="$PWD/agama/tests/01-repo-gpg-criscore.jsonnet"

agama config show > /tmp/agama-before.json
agama config generate "$PROFILE" > /tmp/agama-test01.json
agama config validate /tmp/agama-test01.json
agama config load /tmp/agama-test01.json
agama config show > /tmp/agama-after.json
```

Then inspect:

```bash
diff -u /tmp/agama-before.json /tmp/agama-after.json || true
agama status
agama questions list 2>/dev/null || true
```

Expected result:
- product: Slowroll;
- repository `home_krism` is enabled;
- no unknown-GPG question;
- package `criscore1` is accepted for resolution and its dependency `criscore2` is resolvable;
- no storage action is started.

Do **not** run `agama install` during this test.

OBS signing key fingerprint:
`8528 3DD3 E1AF A9EA 668E 2065 3505 E29C 78A0 0759`
