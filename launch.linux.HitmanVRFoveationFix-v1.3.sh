#!/usr/bin/env bash
# HitmanVRFoveationFix for Linux/Proton - itteration v1.3.3
# Based direct port of RealChrizzl's Windows PowerShell v1.3 implementation.

set -euo pipefail
cd -- "$(dirname -- "$(readlink -f -- "$0")")"
exec sudo python3 -I ./Linux-HitmanVRFoveationFix-v1.3.py "$@"
