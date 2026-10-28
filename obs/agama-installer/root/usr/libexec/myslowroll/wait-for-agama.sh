#!/bin/bash
# ==============================================================================
# wait-for-agama.sh - Attende l'avvio del server HTTP/HTTPS di Agama prima di avviare Firefox
# ==============================================================================
set -euo pipefail

# 0. Garantisce password root impostata a runtime nel sistema live
echo "root:root" | chpasswd 2>/dev/null || true

echo "mySlowrollOS Kiosk: attesa disponibilità del server Agama su localhost..."

for i in {1..60}; do
    if curl -s -f -o /dev/null -m 1 http://localhost/ || curl -s -f -o /dev/null -m 1 http://127.0.0.1/ || curl -s -k -f -o /dev/null -m 1 https://localhost/ || curl -s -k -f -o /dev/null -m 1 https://127.0.0.1/; then
        echo "mySlowrollOS Kiosk: server Agama rilevato su localhost (tentativo $i)."
        echo "root" | agama auth login 2>/dev/null || true
        exit 0
    fi
    sleep 0.5
done

echo "mySlowrollOS Kiosk: avvio Firefox in kiosk mode..."
exit 0
