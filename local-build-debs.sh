#!/usr/bin/env bash
# Build the statusbar Debian packages natively on this (Debian-based) machine,
# for this machine, without a container. See local-build-packages.sh for the
# options and knobs; this fixes the package format to .deb.
set -euo pipefail
PKG_FORMAT=deb exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/local-build-packages.sh" "$@"
