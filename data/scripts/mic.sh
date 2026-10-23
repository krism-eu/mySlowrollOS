#!/usr/bin/env bash
# mySlowrollOS Control Center - Microphone Toggle Script
set -euo pipefail

if ! command -v wpctl >/dev/null 2>&1; then
    exit 1
fi

wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle

vol_out="$(wpctl get-volume @DEFAULT_AUDIO_SOURCE@ 2>/dev/null || true)"
if [[ "$vol_out" == *MUTED* ]]; then
    if command -v notify-send >/dev/null 2>&1; then
        notify-send -a "mySlowrollOS" -i microphone-sensitivity-muted -h string:x-canonical-private-synchronous:mic-status "Microfono DISATTIVATO" "Ingresso audio mutato."
    fi
else
    if command -v notify-send >/dev/null 2>&1; then
        notify-send -a "mySlowrollOS" -i audio-input-microphone -h string:x-canonical-private-synchronous:mic-status "Microfono ATTIVATO" "Ingresso audio attivo."
    fi
fi

