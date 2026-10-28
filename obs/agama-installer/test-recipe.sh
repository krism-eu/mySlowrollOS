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

echo "=== [3/5] Verifica cablaggio sessione Kiosk (Cage + Firefox) ==="
KIOSK_SERVICE="${SCRIPT_DIR}/root/usr/lib/systemd/system/agama-kiosk.service"
if [ ! -f "$KIOSK_SERVICE" ]; then
    echo "FAIL: Unit agama-kiosk.service mancante nell'overlay!" >&2
    exit 1
fi
if ! grep -q "cage" "$KIOSK_SERVICE" || ! grep -q "firefox" "$KIOSK_SERVICE"; then
    echo "FAIL: agama-kiosk.service non invoca cage o firefox!" >&2
    exit 1
fi
if ! grep -q "WantedBy=graphical.target" "$KIOSK_SERVICE"; then
    echo "FAIL: agama-kiosk.service non appartiene a graphical.target!" >&2
    exit 1
fi
echo "PASS: Cablaggio Kiosk verificato (unit presente, target grafico corretto)"

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
