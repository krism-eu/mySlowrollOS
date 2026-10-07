#!/usr/bin/env bash
set -euo pipefail

# Run from a checkout/archive of the reviewed commit. Never starts installation.
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "$HERE/../.." && pwd)
REPORT_DIR=$(mktemp -d /tmp/myslowroll-agama-test02.XXXXXX)
REPORT="$REPORT_DIR/report.txt"
OUT="$REPORT_DIR/profile.json"
exec > >(tee "$REPORT") 2>&1

echo '=== CHECK GENERATED PROFILES ==='
python3 "$ROOT/agama/generate-profiles.py" --check

echo '=== GENERATE ACTUAL FINAL PROFILE ==='
agama config generate "$ROOT/agama/profile-final.jsonnet" > "$OUT"
agama config validate "$OUT"
echo 'VALIDATE=PASS'

echo '=== FETCH AND CHECK THE EXACT PINNED SCRIPTS ==='
python3 - "$OUT" "$REPORT_DIR" <<'PY'
import json, pathlib, re, subprocess, sys, urllib.request
profile = json.load(open(sys.argv[1]))
directory = pathlib.Path(sys.argv[2])
for group, scripts in profile.get('scripts', {}).items():
    for index, script in enumerate(scripts):
        url = script['url']
        if not re.fullmatch(r'https://raw\.githubusercontent\.com/krism-eu/mySlowrollOS/[0-9a-f]{40}/agama/[\w-]+\.sh', url):
            raise SystemExit('Script URL is not pinned: ' + url)
        with urllib.request.urlopen(url, timeout=30) as response:
            content = response.read()
        path = directory / f'{group}-{index}.sh'
        path.write_bytes(content)
        subprocess.run(['bash', '-n', str(path)], check=True)
        print('BASH_N=PASS', url)
PY

echo '=== LOAD / PROBE (NO INSTALL) ==='
agama config load "$OUT"
agama probe
agama status
agama questions list
agama issues list

echo '=== CURRENT CONFIGURATION ==='
agama config show > "$REPORT_DIR/current-config.json"
python3 - "$REPORT_DIR/current-config.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
print(json.dumps({key: data.get(key) for key in ('storage', 'bootloader')}, indent=2))
PY

echo "REPORT=$REPORT"
echo 'NO_INSTALL_WAS_STARTED'
echo 'Profile validation/probe is not an installed-system or first-boot test.'
