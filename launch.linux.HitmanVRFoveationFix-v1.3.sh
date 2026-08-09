#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$(readlink -f -- "$0")")"
exec sudo python3 -I ./Linux-HitmanVRFoveationFix-v1.3.3.py "$@"
