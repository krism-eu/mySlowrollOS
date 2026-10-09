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

echo '=== FETCH AND CHECK ALL EXACT PINNED ASSETS ==='
python3 - "$OUT" "$REPORT_DIR" "$ROOT" <<'PY'
import json, pathlib, re, subprocess, sys, urllib.request
profile = json.load(open(sys.argv[1]))
directory = pathlib.Path(sys.argv[2])
root = pathlib.Path(sys.argv[3])
entries = [(f'{group}-{index}.sh', script, True)
           for group, scripts in profile.get('scripts', {}).items()
           for index, script in enumerate(scripts)]
entries += [(f'policy-{index}', entry, False)
            for index, entry in enumerate(profile.get('files', []))]
revision = (root / 'agama/assets-revision').read_text().strip()
prefix = f'https://raw.githubusercontent.com/krism-eu/mySlowrollOS/{revision}/'
for name, entry, is_script in entries:
    url = entry['url']
    if not url.startswith(prefix):
        raise SystemExit('Asset URL does not use the reviewed pin: ' + url)
    relative = pathlib.PurePosixPath(url[len(prefix):])
    if relative.is_absolute() or '..' in relative.parts or not relative.parts:
        raise SystemExit('Invalid asset path: ' + url)
    local = (root / relative).resolve()
    if not local.is_relative_to(root.resolve()) or not local.is_file():
        raise SystemExit('Missing or escaping local asset: ' + url)
    with urllib.request.urlopen(url, timeout=30) as response:
        content = response.read()
    path = directory / name
    path.write_bytes(content)
    subprocess.run(['cmp', str(path), str(local)], check=True)
    print('PINNED_MATCH=PASS', url)
    if is_script:
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
