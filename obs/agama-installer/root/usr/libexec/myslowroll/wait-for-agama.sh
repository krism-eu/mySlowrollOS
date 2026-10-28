#!/bin/bash
# ==============================================================================
# wait-for-agama.sh - Attende l'avvio del server HTTP di Agama prima di avviare Firefox
# ==============================================================================
set -euo pipefail

echo "mySlowrollOS Kiosk: attesa disponibilità del server Agama su localhost..."

for i in {1..30}; do
    if curl -s -f -o /dev/null -m 1 http://localhost/ || curl -s -f -o /dev/null -m 1 http://127.0.0.1/; then
        echo "mySlowrollOS Kiosk: server Agama rilevato su localhost (tentativo $i)."
        exit 0
    fi
    sleep 1
done

echo "mySlowrollOS Kiosk: timeout attesa Agama (30s), avvio comunque Firefox in kiosk mode."
exit 0
