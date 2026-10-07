#!/usr/bin/env bash
set -euo pipefail

URL='https://raw.githubusercontent.com/krism-eu/mySlowrollOS/main/agama/tests/02-full-vm-validation.jsonnet'
OUT=/tmp/myslowroll-test02.json
REPORT=/tmp/myslowroll-agama-test02-report.txt

exec > >(tee "$REPORT") 2>&1

echo '=== GENERATE ==='
agama config generate "$URL" > "$OUT"
echo 'GENERATE=PASS'

echo '=== VALIDATE ==='
agama config validate "$OUT"
echo 'VALIDATE=PASS'

echo '=== LOAD (NO INSTALL) ==='
agama config load "$OUT"
agama probe

echo '=== STATUS ==='
agama status || true
echo '=== QUESTIONS ==='
agama questions list 2>/dev/null || true
echo '=== ISSUES ==='
agama issues list 2>/dev/null || true

echo '=== BOOTLOADER / STORAGE (STORAGE EXPECTED UNSET) ==='
agama config show >/tmp/myslowroll-test02-current.json
python3 - <<'PY'
import json
d=json.load(open('/tmp/myslowroll-test02-current.json'))
print(json.dumps({'storage':d.get('storage'),'bootloader':d.get('bootloader')},indent=2))
PY

echo '=== DOWNLOADED SCRIPT/FILES ==='
find /run/agama/scripts -maxdepth 3 -type f -print 2>/dev/null | sort || true
grep -RniE 'myslowroll-firstboot-policy|10-myslowroll|home_krism|99-myslowroll' /run/agama 2>/dev/null | head -n 100 || true

echo '=== TARGET SOLVER FINAL ==='
journalctl -b --no-pager | grep -E 'job: install (atomic-update|criscore1|criscore2)|final solver statistics|nothing provides|conflict|problem' | tail -n 120 || true

echo '=== SCRIPT SYNTAX ==='
curl -fsSL https://raw.githubusercontent.com/krism-eu/mySlowrollOS/main/agama/init-firstboot.sh -o /tmp/init-firstboot.sh
bash -n /tmp/init-firstboot.sh
echo 'INIT_BASH_N=PASS'

echo '=== FINAL ==='
agama status || true
echo "REPORT=$REPORT"
echo 'NO_INSTALL_WAS_STARTED'
