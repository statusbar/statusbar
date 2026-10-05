#!/usr/bin/env bash
# Build the statusbar Debian packages natively on this machine, for this
# machine, without a container.
#
# Usage: ./local-build-debs.sh [--install-prereqs] [--clean] [<pkg> ...]
#   (no package)       build every package
#   <pkg> ...          build the named packages and their dependencies;
#                      names may be given as 'core' or 'statusbar-core'
#   --install-prereqs  apt-get install the build prerequisites first (sudo)
#   --clean            discard the previous build trees and staging area
#
# This is the container-free twin of container-build.sh: the same packages,
# in the same dependency order, configured and packaged the same way, but
# compiled by this machine's toolchain for this machine's architecture. Where
# the container installs each dependency's freshly built .deb before building
# the next package, this script installs it into a private staging prefix
# ($BUILD_ROOT/stage) and points the dependents at it with CMAKE_PREFIX_PATH,
# so nothing is installed on the host and no root is needed to build.
#
# Knobs (all optional, same names as container-build.sh):
#   STATUSBAR_TOOLCHAIN=clang|gcc   compiler (default clang; gcc builds C++26
#                                   and needs g++ >= 15)
#   STATUSBAR_STATIC_CXX=ON|OFF     statically link the C++ runtime (default
#                                   ON for gcc, OFF for clang)
#   STATUSBAR_DEB_REVISION=<rev>    Debian revision shared by every package
#                                   built in this run (default: UTC timestamp)
#   DEB_OUTPUT=<dir>                where the .deb files land (default
#                                   deb-output-local[-gcc]/, separate from the
#                                   container builds' deb-output/ because the
#                                   file names are identical)
#   BUILD_ROOT=<dir>                build trees and staging prefix (default
#                                   build-debs[-gcc]/)
#   EXTRA_CMAKE_ARGS="..."          appended to every configure
#
# A package's .deb is rebuilt when its source tree is newer than the .deb,
# or when one of its dependencies was rebuilt during this run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INSTALL_PREREQS=0
CLEAN=0
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --install-prereqs) INSTALL_PREREQS=1 ;;
    --clean) CLEAN=1 ;;
    -h | --help)
      sed -n '2,/^set -euo pipefail/{/^set -euo pipefail/d;s/^# \{0,1\}//;p;}' "$0"
      exit 0
      ;;
    -*)
      echo "error: unknown option '$arg'" >&2
      exit 1
      ;;
    *) ARGS+=("$arg") ;;
  esac
done

# ---- toolchain and output locations ---------------------------------------
STATUSBAR_TOOLCHAIN="${STATUSBAR_TOOLCHAIN:-clang}"
case "$STATUSBAR_TOOLCHAIN" in
  clang) STATUSBAR_STATIC_CXX="${STATUSBAR_STATIC_CXX:-OFF}" ;;
  gcc) STATUSBAR_STATIC_CXX="${STATUSBAR_STATIC_CXX:-ON}" ;;
  *)
    echo "error: STATUSBAR_TOOLCHAIN must be 'clang' or 'gcc'" >&2
    exit 1
    ;;
esac
export STATUSBAR_TOOLCHAIN STATUSBAR_STATIC_CXX

case "$STATUSBAR_TOOLCHAIN" in
  gcc) _suffix="-gcc" ;;
  *) _suffix="" ;;
esac
DEB_OUTPUT="${DEB_OUTPUT:-$ROOT/deb-output-local$_suffix}"
BUILD_ROOT="${BUILD_ROOT:-$ROOT/build-debs$_suffix}"
STAGE="$BUILD_ROOT/stage"
PREFIX=/usr/local
TOOLCHAIN_FILE="$ROOT/core/cmake/toolchain-$STATUSBAR_TOOLCHAIN.cmake"

# ---- prerequisites --------------------------------------------------------
# The same set the builder image (core/Containerfile) installs, so a native
# build sees what the container build sees.
PREREQ_PKGS="clang clang-tools lld libc++-dev libc++abi-dev libclang-rt-dev \
cmake ninja-build ccache pkg-config dpkg-dev file ca-certificates git \
python3 python3-jsonschema libasound2-dev libbpf-dev libxdp-dev libelf-dev zlib1g-dev"
if [ "$STATUSBAR_TOOLCHAIN" = gcc ]; then
  PREREQ_PKGS="$PREREQ_PKGS g++"
fi

if [ "$(uname -s)" != Linux ] || ! command -v dpkg >/dev/null 2>&1; then
  echo "error: this script builds .deb packages natively and needs a Debian-based Linux host." >&2
  echo "       On other hosts use container-build.sh / container-build-cross.sh." >&2
  exit 1
fi

if [ "$INSTALL_PREREQS" -eq 1 ]; then
  echo "=== installing build prerequisites (sudo apt-get) ==="
  # shellcheck disable=SC2086
  sudo apt-get install -y --no-install-recommends $PREREQ_PKGS
fi

missing=""
need_cmd() { command -v "$1" >/dev/null 2>&1 || missing="$missing $2"; }
need_cmd cmake cmake
need_cmd ninja ninja-build
need_cmd pkg-config pkg-config
need_cmd dpkg-deb dpkg-dev
need_cmd dpkg-shlibdeps dpkg-dev
need_cmd file file
need_cmd python3 python3
need_cmd git git
# clang is needed by every toolchain: the XDP filter in statusbar-core is
# built with `clang -target bpf`.
need_cmd clang clang
need_cmd clang++ clang
if [ "$STATUSBAR_TOOLCHAIN" = gcc ]; then
  need_cmd g++ g++
fi
need_lib() { pkg-config --exists "$1" 2>/dev/null || missing="$missing $2"; }
need_lib alsa libasound2-dev
need_lib libbpf libbpf-dev
need_lib libxdp libxdp-dev
need_lib libelf libelf-dev
need_lib zlib zlib1g-dev
python3 -c 'import jsonschema' 2>/dev/null || missing="$missing python3-jsonschema"
if [ "$STATUSBAR_TOOLCHAIN" = clang ]; then
  # libc++ headers: the clang toolchain file builds with -stdlib=libc++.
  if ! printf '#include <vector>\nint main(){}\n' \
       | clang++ -stdlib=libc++ -x c++ -fsyntax-only - >/dev/null 2>&1; then
    missing="$missing libc++-dev libc++abi-dev"
  fi
fi
if [ -n "$missing" ]; then
  echo "error: missing build prerequisites:$missing" >&2
  echo "       install them with:" >&2
  echo "         sudo apt-get install -y --no-install-recommends $PREREQ_PKGS" >&2
  echo "       or re-run with --install-prereqs." >&2
  exit 1
fi
if [ ! -f "$TOOLCHAIN_FILE" ]; then
  echo "error: $TOOLCHAIN_FILE not found (run 'git submodule update --init core')" >&2
  exit 1
fi

# ---- package set ----------------------------------------------------------
# Packages in dependency-first order, exactly as container-build.sh sees them:
# the exported four, then any nested extension package (a private tree dropped
# into the umbrella, NOT a submodule) that carries its own
# scripts/container-build.sh with a DEPS= line.
TOPO="core crypto audio avb"
has() { case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac ; }
EXTRA=""
for _cb in "$ROOT"/*/scripts/container-build.sh; do
  [ -e "$_cb" ] || continue
  _p="$(basename "$(dirname "$(dirname "$_cb")")")"
  has "$TOPO" "$_p" || EXTRA="$EXTRA $_p"
done
TOPO="$TOPO$EXTRA"

tdeps() {
  case "$1" in
    core) echo "" ;;
    crypto) echo "core" ;;
    audio) echo "core" ;;
    avb) echo "core crypto audio" ;;
    *) sed -n 's/^DEPS="\(.*\)"$/\1/p' "$ROOT/$1/scripts/container-build.sh" 2>/dev/null ;;
  esac
}

WANT=""
if [ "${#ARGS[@]}" -eq 0 ]; then
  WANT=" $TOPO "
else
  for arg in "${ARGS[@]}"; do
    p="${arg#statusbar-}"
    if ! has "$TOPO" "$p"; then
      echo "error: unknown package '$arg' (known:$TOPO)" >&2
      exit 1
    fi
    WANT="$WANT $p $(tdeps "$p")"
  done
fi

if [ "$CLEAN" -eq 1 ]; then
  echo "=== removing $BUILD_ROOT ==="
  rm -rf "$BUILD_ROOT"
fi
mkdir -p "$DEB_OUTPUT" "$STAGE"

# Stale if the .deb is missing, or any source file is newer than it.
src_newer() {
  local pkg="$1" tree="$ROOT/$1" deb
  deb="$(ls -1 "$DEB_OUTPUT"/statusbar-"$pkg"_*.deb "$DEB_OUTPUT"/"$pkg"_*.deb 2>/dev/null | head -n1 || true)"
  [ -z "$deb" ] && return 0
  [ -n "$(find "$tree" -type f -newer "$deb" \
            -not -path '*/build/*' -not -path '*/build-*/*' \
            -not -path '*/.git/*' -print -quit)" ]
}

# One Debian revision for the whole run so every package rebuilt now carries
# the same strictly-increasing version and a redeploy always upgrades.
export STATUSBAR_DEB_REVISION="${STATUSBAR_DEB_REVISION:-$(date -u +%Y%m%d%H%M%S)}"

# ccache when available, as in the container.
CCACHE_ARGS=()
if command -v ccache >/dev/null 2>&1; then
  CCACHE_ARGS=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache)
fi

# ---- one package ----------------------------------------------------------
build_pkg() {
  local pkg="$1" tree="$ROOT/$1" build="$BUILD_ROOT/$1"
  local upper version_args=()

  # Dependencies must already be staged (built earlier in this run, or by a
  # previous run into the same BUILD_ROOT).
  local d
  for d in $(tdeps "$pkg"); do
    if [ ! -d "$STAGE$PREFIX/lib/cmake/statusbar-$d" ]; then
      echo "error: dependency statusbar-$d is not staged in $STAGE; build it first" >&2
      exit 1
    fi
  done

  # Package version = the tree's newest release tag, for the packages that
  # take it from the command line (avb, atdecc-control, ...). The others carry
  # the version in their CMakeLists.
  upper="$(printf '%s' "$pkg" | tr 'a-z-' 'A-Z_')"
  if grep -q "STATUSBAR_${upper}_VERSION" "$tree/CMakeLists.txt"; then
    local tag
    tag="${STATUSBAR_PKG_VERSION:-$(git -C "$tree" describe --tags --abbrev=0 \
          --match '[0-9]*.[0-9]*.[0-9]*' 2>/dev/null || true)}"
    if [ -n "$tag" ]; then
      version_args=("-DSTATUSBAR_${upper}_VERSION=$tag")
    fi
  fi

  echo "=== statusbar-$pkg: configure ($STATUSBAR_TOOLCHAIN) ==="
  # shellcheck disable=SC2086
  cmake -Wno-dev -S "$tree" -B "$build" -G Ninja \
    --toolchain "$TOOLCHAIN_FILE" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_PREFIX_PATH="$STAGE$PREFIX" \
    -DENABLE_FUZZING=OFF \
    -DENABLE_STATIC_CXX_RUNTIME="$STATUSBAR_STATIC_CXX" \
    "${CCACHE_ARGS[@]}" \
    "${version_args[@]}" \
    ${EXTRA_CMAKE_ARGS:-}

  echo "=== statusbar-$pkg: build ==="
  cmake --build "$build"

  echo "=== statusbar-$pkg: package (revision $STATUSBAR_DEB_REVISION) ==="
  rm -f "$build"/*.deb
  cpack -G DEB --config "$build/CPackConfig.cmake" -B "$build" \
    -D CPACK_DEBIAN_PACKAGE_RELEASE="$STATUSBAR_DEB_REVISION"
  rm -f "$DEB_OUTPUT"/statusbar-"$pkg"_*.deb "$DEB_OUTPUT"/statusbar-"$pkg"-*_*.deb
  cp -v "$build"/*.deb "$DEB_OUTPUT"/

  # Stage the install so the next packages' find_package(statusbar-<pkg>)
  # resolves to what was just built, as the container's apt-get install does.
  echo "=== statusbar-$pkg: stage into $STAGE ==="
  rm -rf "$STAGE$PREFIX/lib/cmake/statusbar-$pkg"
  DESTDIR="$STAGE" cmake --install "$build" >/dev/null
}

echo "=== native .deb build: toolchain $STATUSBAR_TOOLCHAIN, arch $(dpkg --print-architecture) ==="
echo "=== output: $DEB_OUTPUT   build trees: $BUILD_ROOT ==="
echo "=== deb revision for this run: $STATUSBAR_DEB_REVISION ==="

REBUILT=""
count=0
for pkg in $TOPO; do
  has "$WANT" "$pkg" || continue
  stale=0
  for d in $(tdeps "$pkg"); do
    if has "$REBUILT" "$d"; then stale=1; fi
  done
  if [ "$stale" -eq 0 ] && ! src_newer "$pkg" \
     && [ -d "$STAGE$PREFIX/lib/cmake/statusbar-$pkg" ]; then
    echo "$pkg: up to date"
    continue
  fi
  build_pkg "$pkg"
  REBUILT="$REBUILT $pkg"
  count=$((count + 1))
done

echo "=== done: $count package(s) (re)built; .deb files in $DEB_OUTPUT ==="
ls -1 "$DEB_OUTPUT"/*.deb 2>/dev/null || true
