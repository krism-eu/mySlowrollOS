#!/usr/bin/env bash
set -euo pipefail

REPORT=/tmp/myslowroll-agama-live-audit.txt
exec > >(tee "$REPORT") 2>&1

BASE='https://raw.githubusercontent.com/krism-eu/mySlowrollOS/main'
PROFILE_SRC="$BASE/agama/workstation-partial-agama24.json"
POST_SRC="$BASE/agama/post-install.sh"
FULL=/tmp/myslowroll-full-software-test.json

echo "=== 1. CURRENT AGAMA STATUS ==="
agama status || true
echo

echo "=== 2. CURRENT QUESTIONS / ISSUES ==="
agama questions list 2>/dev/null || true
agama issues list 2>/dev/null || true
echo

echo "=== 3. TARGET REPOSITORY ==="
cat /run/agama/zypp/etc/zypp/repos.d/home_krism.repo 2>/dev/null || true
echo

echo "=== 4. TARGET CACHE: CRISCORE ==="
grep -aE 'criscore1|criscore2' /run/agama/zypp/var/cache/zypp/solv/home_krism/solv.idx 2>/dev/null || true
echo

echo "=== 5. BUILD FULL SOFTWARE-ONLY TEST PROFILE ==="
python3 - "$PROFILE_SRC" "$FULL" <<'PY'
import json, sys, urllib.request
src, out = sys.argv[1:3]
with urllib.request.urlopen(src, timeout=30) as r:
    d=json.load(r)

d["product"]={"id":"Slowroll"}
d["root"]={"password":"test1234"}

# This audit is software/repository-only. Storage and scripts are tested separately.
d.pop("storage", None)
d.pop("scripts", None)

sw=d.setdefault("software", {})
pkgs=sw.setdefault("packages", [])
if "atomic-update" not in pkgs:
    pkgs.append("atomic-update")
if "criscore1" not in pkgs:
    pkgs.append("criscore1")
# criscore2 must be pulled by criscore1's dependency, but keeping it explicit
# here also verifies that both binary packages are visible.
if "criscore2" not in pkgs:
    pkgs.append("criscore2")

repos=sw.setdefault("extraRepositories", [])
repo=None
for x in repos:
    if x.get("url")=="https://download.opensuse.org/repositories/home:/krism/openSUSE_Slowroll/":
        repo=x
        break
if repo is None:
    repo={
      "alias":"home_krism",
      "name":"home:krism - openSUSE Slowroll",
      "url":"https://download.opensuse.org/repositories/home:/krism/openSUSE_Slowroll/",
      "priority":90
    }
    repos.append(repo)
repo["alias"]="home_krism"
repo["gpgFingerprints"]=["8528 3DD3 E1AF A9EA 668E 2065 3505 E29C 78A0 0759"]
sw["patterns"]=[]
sw["onlyRequired"]=True

with open(out,"w") as f:
    json.dump(d,f,indent=2)
print(f"packages={len(pkgs)}")
PY

agama config validate "$FULL"
echo "VALIDATION=PASS"
echo

echo "=== 6. LOAD FULL SOFTWARE PROFILE ==="
agama config load "$FULL"
agama probe
echo

echo "=== 7. STATUS AFTER FULL SOLVE ==="
agama status || true
echo
echo "--- questions ---"
agama questions list 2>/dev/null || true
echo
echo "--- issues ---"
agama issues list 2>/dev/null || true
echo

echo "=== 8. VERIFY TARGET REPO + GPG CONFIG ==="
cat /run/agama/zypp/etc/zypp/repos.d/home_krism.repo 2>/dev/null || true
grep -RniE '8528.?3DD3|home_krism|home:/krism' /run/agama/zypp/etc/zypp /run/agama/zypp/var/log 2>/dev/null | tail -n 100 || true
echo

echo "=== 9. VERIFY ALL REQUESTED PACKAGES AGAINST AGAMA TARGET SOLVER ROOT ==="
python3 - "$FULL" >/tmp/myslowroll-requested-packages.txt <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for p in sorted(set(d["software"]["packages"])):
    print(p)
PY

missing=0
: >/tmp/myslowroll-missing-packages.txt
while IFS= read -r p; do
    if zypper --root /run/agama/zypp --no-refresh --non-interactive se -s -x "$p" 2>/dev/null | grep -Fq "| $p "; then
        printf 'OK      %s\n' "$p"
    else
        printf 'MISSING %s\n' "$p"
        printf '%s\n' "$p" >>/tmp/myslowroll-missing-packages.txt
        missing=$((missing+1))
    fi
done </tmp/myslowroll-requested-packages.txt

echo
echo "MISSING_COUNT=$missing"
if (( missing > 0 )); then
    echo "--- missing packages ---"
    cat /tmp/myslowroll-missing-packages.txt
fi
echo

echo "=== 10. CRISCORE EXACT VERSIONS IN AGAMA TARGET CACHE ==="
grep -aE 'criscore1|criscore2' /run/agama/zypp/var/cache/zypp/solv/home_krism/solv.idx 2>/dev/null || true
echo

echo "=== 11. SOLVER RESULT ==="
journalctl -b --no-pager | grep -E 'solver statistics|final solver statistics|job: install criscore|job: install atomic-update|nothing provides|conflict|problem' | tail -n 200 || true
echo

echo "=== 12. POST-INSTALL SCRIPT FETCH + SYNTAX ==="
curl -fL --retry 2 "$POST_SRC" -o /tmp/post-install.sh
bash -n /tmp/post-install.sh
echo "POST_INSTALL_BASH_N=PASS"
echo

echo "=== 13. BOOT / STORAGE OBSERVATION (NO CHANGES) ==="
agama config show >/tmp/myslowroll-current-config.json
python3 - <<'PY'
import json
d=json.load(open("/tmp/myslowroll-current-config.json"))
print("bootloader=", json.dumps(d.get("bootloader"), indent=2))
print("storage=", json.dumps(d.get("storage"), indent=2))
PY
echo

echo "=== 14. FINAL ==="
agama status || true
echo "REPORT=$REPORT"
echo "NO_INSTALL_WAS_STARTED"
