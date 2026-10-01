#!/usr/bin/env bash
# Build, sign and install Strumline on a USB-connected, unlocked iPhone.
# The Swift toolchain's own bin dir must come first on PATH (swift-bin only
# links the main commands into /usr/bin).
set -euo pipefail
cd "$(dirname "$0")"
export PATH=/usr/lib/swift/bin:$PATH
exec xtool dev "$@"
