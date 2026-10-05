#!/usr/bin/env bash
# Build the statusbar packages natively on this machine, for this machine,
# without a container: .deb files on a Debian-based host, .rpm files on a
# Fedora/RHEL-based host.
#
# Usage: ./local-build-packages.sh [--install-prereqs] [--clean] [<pkg> ...]
#   (no package)       build every package
#   <pkg> ...          build the named packages and their dependencies;
#                      names may be given as 'core' or 'statusbar-core'
#   --install-prereqs  install the build prerequisites first (sudo apt-get /
#                      sudo dnf)
#   --clean            discard the previous build trees and staging area
#
# local-build-debs.sh and local-build-rpms.sh are the same script with the
# package format fixed; run bare, it picks the format from the host (dpkg or
# rpm). Override with PKG_FORMAT=deb|rpm.
#
# This is the container-free twin of container-build.sh: the same packages,
# in the same dependency order, configured and packaged the same way, but
# compiled by this machine's toolchain for this machine's architecture. Where
# the container installs each dependency's freshly built package before
# building the next one, this script installs it into a private staging
# prefix ($BUILD_ROOT/stage) and points the dependents at it with
# CMAKE_PREFIX_PATH, so nothing is installed on the host and no root is
# needed to build.
#
# Knobs (all optional, same names as container-build.sh):
#   STATUSBAR_TOOLCHAIN=clang|gcc   compiler (default clang; gcc builds C++26
#                                   and needs g++ >= 15)
#   STATUSBAR_STATIC_CXX=ON|OFF     statically link the C++ runtime (default
#                                   ON for gcc, OFF for clang)
#   STATUSBAR_DEB_REVISION=<rev>    package revision shared by every package
#                                   built in this run, used for the Debian
#                                   revision and the RPM release alike
#                                   (default: UTC timestamp)
#   PKG_OUTPUT=<dir>                where the packages land (default
#                                   deb-output-local[-gcc]/ or
#                                   rpm-output-local[-gcc]/, separate from
#                                   the container builds' deb-output/ because
#                                   the file names are identical)
#   BUILD_ROOT=<dir>                build trees and staging prefix (default
#                                   build-debs[-gcc]/ or build-rpms[-gcc]/)
#   EXTRA_CMAKE_ARGS="..."          appended to every configure
#
# A package is rebuilt when its source tree is newer than its package file,
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

# ---- package format -------------------------------------------------------
if [ "$(uname -s)" != Linux ]; then
  echo "error: this script builds packages natively and needs a Linux host." >&2
  echo "       On other hosts use container-build.sh / container-build-cross.sh." >&2
  exit 1
fi
if [ -z "${PKG_FORMAT:-}" ]; then
  if command -v dpkg >/dev/null 2>&1; then
    PKG_FORMAT=deb
  elif command -v rpm >/dev/null 2>&1; then
    PKG_FORMAT=rpm
  else
    echo "error: neither dpkg nor rpm found; cannot tell which package format to build." >&2
    exit 1
  fi
fi
case "$PKG_FORMAT" in
  deb)
    command -v dpkg >/dev/null 2>&1 || {
      echo "error: PKG_FORMAT=deb needs a Debian-based host (no dpkg found)" >&2
      exit 1
    }
    CPACK_GEN=DEB
    RELEASE_VAR=CPACK_DEBIAN_PACKAGE_RELEASE
    PKG_EXT=deb
    OUT_NAME=deb-output-local
    BUILD_NAME=build-debs
    ;;
  rpm)
    command -v rpm >/dev/null 2>&1 || {
      echo "error: PKG_FORMAT=rpm needs an RPM-based host (no rpm found)" >&2
      exit 1
    }
    CPACK_GEN=RPM
    RELEASE_VAR=CPACK_RPM_PACKAGE_RELEASE
    PKG_EXT=rpm
    OUT_NAME=rpm-output-local
    BUILD_NAME=build-rpms
    ;;
  *)
    echo "error: PKG_FORMAT must be 'deb' or 'rpm'" >&2
    exit 1
    ;;
esac

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
PKG_OUTPUT="${PKG_OUTPUT:-$ROOT/$OUT_NAME$_suffix}"
BUILD_ROOT="${BUILD_ROOT:-$ROOT/$BUILD_NAME$_suffix}"
STAGE="$BUILD_ROOT/stage"
PREFIX=/usr/local
TOOLCHAIN_FILE="$ROOT/core/cmake/toolchain-$STATUSBAR_TOOLCHAIN.cmake"

# ---- prerequisites --------------------------------------------------------
# The same set the builder image (core/Containerfile) installs, so a native
# build sees what the container build sees; named per distribution family.
case "$PKG_FORMAT" in
  deb)
    PREREQ_PKGS="clang clang-tools lld libc++-dev libc++abi-dev libclang-rt-dev \
cmake ninja-build ccache pkg-config dpkg-dev file ca-certificates git \
python3 python3-jsonschema libasound2-dev libbpf-dev libxdp-dev libelf-dev zlib1g-dev"
    [ "$STATUSBAR_TOOLCHAIN" = gcc ] && PREREQ_PKGS="$PREREQ_PKGS g++"
    INSTALL_CMD="sudo apt-get install -y --no-install-recommends"
    ;;
  rpm)
    # zlib: Fedora >= 40 ships zlib-ng-compat-devel, older Fedora and RHEL
    # ship zlib-devel; either satisfies pkg-config's zlib.
    _zlib="zlib-devel"
    if command -v dnf >/dev/null 2>&1 && dnf -q list --available zlib-ng-compat-devel >/dev/null 2>&1; then
      _zlib="zlib-ng-compat-devel"
    fi
    PREREQ_PKGS="clang clang-tools-extra lld libcxx-devel libcxxabi-devel compiler-rt \
cmake ninja-build ccache pkgconf-pkg-config rpm-build file git \
python3 python3-jsonschema alsa-lib-devel libbpf-devel libxdp-devel elfutils-libelf-devel $_zlib"
    [ "$STATUSBAR_TOOLCHAIN" = gcc ] && PREREQ_PKGS="$PREREQ_PKGS gcc-c++"
    INSTALL_CMD="sudo dnf install -y"
    ;;
esac

if [ "$INSTALL_PREREQS" -eq 1 ]; then
  echo "=== installing build prerequisites ($INSTALL_CMD) ==="
  # shellcheck disable=SC2086
  $INSTALL_CMD $PREREQ_PKGS
fi

missing=""
need_cmd() { command -v "$1" >/dev/null 2>&1 || missing="$missing $2"; }
need_cmd cmake cmake
need_cmd ninja ninja-build
need_cmd pkg-config pkg-config
need_cmd file file
need_cmd python3 python3
need_cmd git git
case "$PKG_FORMAT" in
  deb)
    need_cmd dpkg-deb dpkg-dev
    need_cmd dpkg-shlibdeps dpkg-dev
    ;;
  rpm) need_cmd rpmbuild rpm-build ;;
esac
# clang is needed by every toolchain: the XDP filter in statusbar-core is
# built with `clang -target bpf`.
need_cmd clang clang
need_cmd clang++ clang
if [ "$STATUSBAR_TOOLCHAIN" = gcc ]; then
  need_cmd g++ "g++/gcc-c++"
fi
need_lib() { pkg-config --exists "$1" 2>/dev/null || missing="$missing $2"; }
case "$PKG_FORMAT" in
  deb)
    need_lib alsa libasound2-dev
    need_lib libbpf libbpf-dev
    need_lib libxdp libxdp-dev
    need_lib libelf libelf-dev
    need_lib zlib zlib1g-dev
    ;;
  rpm)
    need_lib alsa alsa-lib-devel
    need_lib libbpf libbpf-devel
    need_lib libxdp libxdp-devel
    need_lib libelf elfutils-libelf-devel
    need_lib zlib "zlib-devel/zlib-ng-compat-devel"
    ;;
esac
python3 -c 'import jsonschema' 2>/dev/null || missing="$missing python3-jsonschema"
if [ "$STATUSBAR_TOOLCHAIN" = clang ]; then
  # libc++ headers: the clang toolchain file builds with -stdlib=libc++.
  if ! printf '#include <vector>\nint main(){}\n' \
       | clang++ -stdlib=libc++ -x c++ -fsyntax-only - >/dev/null 2>&1; then
    case "$PKG_FORMAT" in
      deb) missing="$missing libc++-dev libc++abi-dev" ;;
      rpm) missing="$missing libcxx-devel libcxxabi-devel" ;;
    esac
  fi
fi
if [ -n "$missing" ]; then
  echo "error: missing build prerequisites:$missing" >&2
  echo "       install them with:" >&2
  echo "         $INSTALL_CMD $PREREQ_PKGS" >&2
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

# A package that opts out of RPMs (NO_RPM in its CPack defaults, e.g. a
# private DEB-only extension) is skipped by the rpm build.
builds_format() {
  case "$PKG_FORMAT" in
    rpm) ! grep -q 'NO_RPM' "$ROOT/$1/CMakeLists.txt" ;;
    *) return 0 ;;
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
mkdir -p "$PKG_OUTPUT" "$STAGE"

# Package files of statusbar-<pkg> (runtime, -dev/-devel and any extra
# component) in the output directory.
pkg_files() {
  case "$PKG_FORMAT" in
    deb) ls -1 "$PKG_OUTPUT"/statusbar-"$1"_*.deb "$PKG_OUTPUT"/statusbar-"$1"-*_*.deb 2>/dev/null || true ;;
    rpm) ls -1 "$PKG_OUTPUT"/statusbar-"$1"-[0-9]*.rpm "$PKG_OUTPUT"/statusbar-"$1"-*-[0-9]*.rpm 2>/dev/null || true ;;
  esac
}

# Stale if the package file is missing, or any source file is newer than it.
src_newer() {
  local pkg="$1" tree="$ROOT/$1" file
  file="$(pkg_files "$pkg" | head -n1)"
  [ -z "$file" ] && return 0
  [ -n "$(find "$tree" -type f -newer "$file" \
            -not -path '*/build/*' -not -path '*/build-*/*' \
            -not -path '*/.git/*' -print -quit)" ]
}

# One revision for the whole run so every package rebuilt now carries the
# same strictly-increasing version and a redeploy always upgrades.
export STATUSBAR_DEB_REVISION="${STATUSBAR_DEB_REVISION:-$(date -u +%Y%m%d%H%M%S)}"

# ccache when available, as in the container.
CCACHE_ARGS=()
if command -v ccache >/dev/null 2>&1; then
  CCACHE_ARGS=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache)
fi

# The staged CMake package config of statusbar-<pkg>, wherever this host's
# GNUInstallDirs put it (lib/ on Debian, lib64/ on Fedora/RHEL); empty if the
# package is not staged.
staged_config() {
  ls -d "$STAGE$PREFIX"/lib*/cmake/statusbar-"$1" 2>/dev/null | head -n1 || true
}

# ---- one package ----------------------------------------------------------
build_pkg() {
  local pkg="$1" tree="$ROOT/$1" build="$BUILD_ROOT/$1"
  local upper version_args=()

  # Dependencies must already be staged (built earlier in this run, or by a
  # previous run into the same BUILD_ROOT).
  local d
  for d in $(tdeps "$pkg"); do
    if [ -z "$(staged_config "$d")" ]; then
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

  echo "=== statusbar-$pkg: package ($CPACK_GEN, revision $STATUSBAR_DEB_REVISION) ==="
  rm -f "$build"/*."$PKG_EXT"
  cpack -G "$CPACK_GEN" --config "$build/CPackConfig.cmake" -B "$build" \
    -D "$RELEASE_VAR=$STATUSBAR_DEB_REVISION"
  local old
  for old in $(pkg_files "$pkg"); do
    rm -f "$old"
  done
  cp -v "$build"/*."$PKG_EXT" "$PKG_OUTPUT"/

  # Stage the install so the next packages' find_package(statusbar-<pkg>)
  # resolves to what was just built, as the container's package install does.
  echo "=== statusbar-$pkg: stage into $STAGE ==="
  rm -rf "$STAGE$PREFIX"/lib*/cmake/statusbar-"$pkg"
  DESTDIR="$STAGE" cmake --install "$build" >/dev/null
}

case "$PKG_FORMAT" in
  deb) _arch="$(dpkg --print-architecture)" ;;
  rpm) _arch="$(rpm --eval '%{_arch}')" ;;
esac
echo "=== native $PKG_EXT build: toolchain $STATUSBAR_TOOLCHAIN, arch $_arch ==="
echo "=== output: $PKG_OUTPUT   build trees: $BUILD_ROOT ==="
echo "=== revision for this run: $STATUSBAR_DEB_REVISION ==="

REBUILT=""
count=0
for pkg in $TOPO; do
  has "$WANT" "$pkg" || continue
  if ! builds_format "$pkg"; then
    echo "$pkg: no $PKG_EXT packages (NO_RPM), skipped"
    continue
  fi
  stale=0
  for d in $(tdeps "$pkg"); do
    if has "$REBUILT" "$d"; then stale=1; fi
  done
  if [ "$stale" -eq 0 ] && ! src_newer "$pkg" \
     && [ -n "$(staged_config "$pkg")" ]; then
    echo "$pkg: up to date"
    continue
  fi
  build_pkg "$pkg"
  REBUILT="$REBUILT $pkg"
  count=$((count + 1))
done

echo "=== done: $count package(s) (re)built; $PKG_EXT files in $PKG_OUTPUT ==="
ls -1 "$PKG_OUTPUT"/*."$PKG_EXT" 2>/dev/null || true
