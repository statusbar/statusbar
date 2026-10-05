#!/usr/bin/env bash
# Build the statusbar RPM packages natively on this (Fedora/RHEL-based)
# machine, for this machine, without a container. See local-build-packages.sh
# for the options and knobs; this fixes the package format to .rpm.
set -euo pipefail
PKG_FORMAT=rpm exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/local-build-packages.sh" "$@"
