#!/bin/bash

check() {
    return 0
}

depends() {
    echo "bash"
    return 0
}

installkernel() {
    instmods overlay
}

install() {
    inst_hook pre-pivot 90 "$moddir/mount-overlay.sh"
    inst_multiple mount findmnt mkdir rm mv cp cat touch date find
}
