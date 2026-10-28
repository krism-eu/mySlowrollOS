#!/bin/bash
# ==============================================================================
# test-recipe.sh - CI regression check for Agama Installer KIWI recipe and overlay
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "=== [1/4] Verifica sintassi script config.sh ==="
bash -n "${SCRIPT_DIR}/config.sh"
echo "PASS: config.sh sintatticamente corretto"

echo "=== [2/4] Verifica integrità overlay e profilo offline ==="
python3 "${SCRIPT_DIR}/sync-installer-assets.py" --check
echo "PASS: sync-installer-assets.py --check superato"

echo "=== [3/4] Verifica assenza file delta obsoleti ==="
if [ -f "${SCRIPT_DIR}/config.sh.delta" ] || [ -f "${SCRIPT_DIR}/iso-delta.kiwi.xml" ]; then
    echo "FAIL: Trovati file delta obsoleti in ${SCRIPT_DIR}" >&2
    exit 1
fi
echo "PASS: Nessun file delta obsoleto presente"

echo "=== [4/4] Validazione schema RELAX NG di agama-installer.kiwi ==="
SCHEMA_FILE=""
for candidate in \
    "/tmp/s_v10.3.11.rng" \
    "/tmp/kiwi.rng" \
    "/usr/share/kiwi/schema/kiwi.rng"; do
    if [ -f "$candidate" ]; then
        SCHEMA_FILE="$candidate"
        break
    fi
done

if [ -n "$SCHEMA_FILE" ]; then
    xmllint --noout --relaxng "$SCHEMA_FILE" "${SCRIPT_DIR}/agama-installer.kiwi"
    echo "PASS: agama-installer.kiwi validato con successo contro $SCHEMA_FILE"
else
    # Fallback su verifica ben formata se nessuno schema RNG è installato nel runner
    xmllint --noout "${SCRIPT_DIR}/agama-installer.kiwi"
    echo "PASS: agama-installer.kiwi XML ben formato (schema RNG locale non trovato, skipped validation)"
fi

echo "=== TUTTI I TEST DELL'INSTALLER SUPERATI CON SUCCESSO ==="
exit 0
