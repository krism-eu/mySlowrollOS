#!/bin/bash
# ==============================================================================
# test-recipe.sh - CI regression check for Agama Installer KIWI recipe and overlay
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "=== [1/5] Verifica sintassi script bash ==="
bash -n "${SCRIPT_DIR}/config.sh"
bash -n "${SCRIPT_DIR}/root/usr/libexec/myslowroll/wait-for-agama.sh"
echo "PASS: config.sh e wait-for-agama.sh sintatticamente corretti"

echo "=== [2/5] Verifica integrità overlay e profilo offline ==="
python3 "${SCRIPT_DIR}/sync-installer-assets.py" --check
echo "PASS: sync-installer-assets.py --check superato"

echo "=== [2b/5] Verifica shim agama-cmdline-process (root cause autoinstall fallito) ==="
CMDLINE_UNIT="${SCRIPT_DIR}/root/usr/lib/systemd/system/agama-cmdline-process.service"
CMDLINE_SH="${SCRIPT_DIR}/root/usr/libexec/myslowroll/agama-cmdline-process.sh"
test -f "${CMDLINE_UNIT}" || { echo "ERRORE: mancante ${CMDLINE_UNIT}" >&2; exit 1; }
test -f "${CMDLINE_SH}"   || { echo "ERRORE: mancante ${CMDLINE_SH}" >&2; exit 1; }
grep -q "WantedBy=multi-user.target" "${CMDLINE_UNIT}" || { echo "ERRORE: unit non installabile in multi-user.target" >&2; exit 1; }
grep -q "Before=.*agama-autoinstall.service" "${CMDLINE_UNIT}" || { echo "ERRORE: unit senza ordering Before=agama-autoinstall" >&2; exit 1; }
bash -n "${CMDLINE_SH}"
grep -q "CMDLINE_DIR}/agama.conf" "${CMDLINE_SH}" || { echo "ERRORE: script non scrive cmdline.d/agama.conf" >&2; exit 1; }
grep -q "CMDLINE_DIR}/kernel.conf" "${CMDLINE_SH}" || { echo "ERRORE: script non scrive cmdline.d/kernel.conf" >&2; exit 1; }
test "$(stat -c '%a' "${CMDLINE_SH}")" = "755" || { echo "ERRORE: permessi ${CMDLINE_SH} != 0755" >&2; exit 1; }
echo "PASS: shim agama-cmdline-process presente, ordinato prima di agama-autoinstall, scrive cmdline.d"

echo "=== [3/5] Verifica cablaggio sessione Kiosk (Cage + Firefox + Input + Policies) ==="
KIOSK_SERVICE="${SCRIPT_DIR}/root/usr/lib/systemd/system/agama-kiosk.service"
if [ ! -f "$KIOSK_SERVICE" ]; then
    echo "FAIL: Unit agama-kiosk.service mancante nell'overlay!" >&2
    exit 1
fi
if ! grep -q "cage" "$KIOSK_SERVICE" || ! grep -q "firefox" "$KIOSK_SERVICE"; then
    echo "FAIL: agama-kiosk.service non invoca cage o firefox!" >&2
    exit 1
fi
if grep -q "WLR_LIBINPUT_NO_DEVICES" "$KIOSK_SERVICE"; then
    echo "FAIL: agama-kiosk.service contiene WLR_LIBINPUT_NO_DEVICES (blocca mouse/tastiera)!" >&2
    exit 1
fi
if grep -q -- "--private-window" "$KIOSK_SERVICE"; then
    echo "FAIL: agama-kiosk.service contiene --private-window (disabilita persistenza cert/token)!" >&2
    exit 1
fi
if ! grep -q "https://localhost/" "$KIOSK_SERVICE"; then
    echo "FAIL: agama-kiosk.service non usa https://localhost/!" >&2
    exit 1
fi
if [ ! -f "${SCRIPT_DIR}/root/etc/firefox/policies/policies.json" ]; then
    echo "FAIL: Enterprise policies Firefox mancante in root/etc/firefox/policies/policies.json!" >&2
    exit 1
fi
if ! grep -q "WantedBy=graphical.target" "$KIOSK_SERVICE"; then
    echo "FAIL: agama-kiosk.service non appartiene a graphical.target!" >&2
    exit 1
fi
echo "PASS: Cablaggio Kiosk verificato (input attivi, https, policies enterprise, graphical.target)"

echo "=== [4/5] Verifica assenza file delta obsoleti ==="
if [ -f "${SCRIPT_DIR}/config.sh.delta" ] || [ -f "${SCRIPT_DIR}/iso-delta.kiwi.xml" ]; then
    echo "FAIL: Trovati file delta obsoleti in ${SCRIPT_DIR}" >&2
    exit 1
fi
echo "PASS: Nessun file delta obsoleto presente"

echo "=== [5/5] Validazione schema RELAX NG di agama-installer.kiwi (Kiwi 10.3 / 8.5) ==="
SCHEMA_FILE="${SCRIPT_DIR}/schema/kiwi-8.5.rng"
if [ ! -f "$SCHEMA_FILE" ]; then
    echo "FAIL: Schema RelaxNG Kiwi 8.5 non trovato in $SCHEMA_FILE!" >&2
    echo "La validazione di schema è obbligatoria e non può essere saltata." >&2
    exit 1
fi

xmllint --noout --relaxng "$SCHEMA_FILE" "${SCRIPT_DIR}/agama-installer.kiwi"
echo "PASS: agama-installer.kiwi validato con successo contro $SCHEMA_FILE"

echo "=== TUTTI I 5 TEST DELL'INSTALLER SUPERATI CON SUCCESSO ==="
exit 0
