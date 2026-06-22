# statusbar

Open-source C++23 building blocks for **time-synchronised, real-time audio
networking** — and the embedded platform tooling to run it.

This is an umbrella index for my public repositories on Codeberg. Everything
below lives under [**codeberg.org/statusbar**](https://codeberg.org/statusbar).

— Jeff Koftinoff · California · <https://avb.statusbar.com/>

---

## The stack

The libraries layer cleanly: `core` is the foundation, `crypto` and `audio`
build on it, and `avb` ties everything together into a full AVB/TSN
implementation.

| Repository | Language | What it is |
| --- | --- | --- |
| [**avb**](https://codeberg.org/statusbar/avb) | C++23 | AVB/TSN protocol family — the flagship project (see below). |
| [**audio**](https://codeberg.org/statusbar/audio) | C++23 | Audio toolkit: DSP primitives, real-time data-flow engine, low-latency cross-platform audio I/O, SMPTE timecode, MIDI, and Open Sound Control. |
| [**crypto**](https://codeberg.org/statusbar/crypto) | C++23 | Cryptography toolkit: AES (block, CBC, GCM-SIV, SIV, CMAC), SHA-2, POLYVAL, HKDF/KDF2, Curve25519 (X25519/Ed25519), NIST P-256 (ECDH/ECDSA), ECIES, and PKCS#8 — hardware-accelerated (ARMv8 Crypto Extensions; AES-NI/PCLMUL/SHA-NI on x86-64) with portable software fallbacks. |
| [**core**](https://codeberg.org/statusbar/core) | C++23 | Foundational utilities: error handling, zero-copy buffers, IEEE and networking primitives, state machines, inter-thread communication, real-time scheduling, and terminal UI. |

## Platform & tooling

The hardware and OS layer for running this stack on Raspberry Pi 5 and
microcontrollers.

| Repository | Language | What it is |
| --- | --- | --- |
| [**rtkernel**](https://codeberg.org/statusbar/rtkernel) | Shell | Scripts to configure and build a Linux kernel for Debian trixie on the Raspberry Pi 5, tuned for real-time operation and isolated CPU cores. |
| [**linuxptp4avb**](https://codeberg.org/statusbar/linuxptp4avb) | Shell | LinuxPTP (`ptp4l`) configuration for the Raspberry Pi 5 to support gPTP (IEEE 802.1AS) with an external grandmaster synced to GPS TAI time. |
| [**zephyr**](https://codeberg.org/statusbar/zephyr) | Shell | Zephyr RTOS test applications for the statusbar libraries. |

---

## About avb

[`statusbar/avb`](https://codeberg.org/statusbar/avb) is a C++23 implementation
of the AVB/TSN (Audio Video Bridging / Time-Sensitive Networking) protocol
family:

- **IEEE 1722** — AVTP audio transport
- **IEEE 1722.1** — ATDECC device discovery, control, and connection management
- **IEEE 802.1AS** — gPTP time synchronisation
- **IEEE 802.1Q** — MSRP/MVRP stream reservation

It ships protocol modules (`avtp`, `atdecc`, `gptp`, `srp`, and the integrated
`nanoavb` entity stack) plus a broad set of command-line tools: ATDECC
controllers and monitors, a Linux gPTP slave and NTP-SHM bridge, AVTP
capture/replay/decode utilities, and turn-key AVB audio entities. It also
includes AVB/TSN-adjacent networking and measurement tooling — `udptun`
(gPTP-timestamped UDP framework), `owlm` (one-way latency measurement), a
`stun` client/server (RFC 8489), and `netdump` (AVB/AVTP-aware packet capture).

---

## Cloning everything

Every project is included here as a git submodule, so a recursive clone of this
umbrella pulls them all:

```sh
git clone --recursive https://codeberg.org/statusbar/umbrella.git
```

Already cloned without `--recursive`? Pull the submodules with:

```sh
git submodule update --init --recursive
```

---

## Building

The four C++ libraries (`core`, `crypto`, `audio`, `avb`) build together as a
single aggregate CMake project, so you can open the umbrella as one project in
your IDE. The build uses Clang with libc++; the bundled toolchain file picks the
compiler up automatically.

> **The toolchain file is required.** `cmake/toolchain-clang.cmake` defines the
> shared build helpers (fuzzing, coverage, clang-tidy, sanitizers). A plain
> `cmake -S .` without it will fail with `Unknown CMake command
> "statusbar_register_fuzz_targets"`.

### Prerequisites

- **macOS:** Homebrew LLVM (`brew install llvm`) for Clang + libc++, plus
  `brew install cmake ninja`. Linux-only components (AF_XDP, BPF) are compiled
  out automatically.
- **Debian/Ubuntu (incl. Raspberry Pi 5):** the stock LLVM toolchain and dev
  libraries:
  ```sh
  sudo apt install clang clang-tools clangd lld llvm libc++-dev libc++abi-dev \
      cmake ninja-build ccache pkg-config \
      libasound2-dev libbpf-dev libxdp-dev libelf-dev zlib1g-dev
  ```

### Quick build

```sh
./local-build.sh            # configure + build + ctest, into ./build
BUILD_DIR=build-rel ./local-build.sh -DCMAKE_BUILD_TYPE=Release
```

`local-build.sh` is a thin wrapper around:

```sh
cmake -G Ninja -B build -S . --toolchain cmake/toolchain-clang.cmake
cmake --build build
ctest --test-dir build
```

### IDE setup

Point your IDE's CMake configuration at the toolchain file:

- **CLion:** *Settings → Build, Execution, Deployment → CMake → CMake options:*
  `--toolchain cmake/toolchain-clang.cmake`
- **VS Code (CMake Tools):** add to `.vscode/settings.json`:
  ```json
  { "cmake.configureArgs": ["--toolchain", "cmake/toolchain-clang.cmake"] }
  ```

### Debian packages

Reproducible `.deb` builds for each library run in a Debian container (needs
`podman` or `docker`):

```sh
./container-build.sh             # build every package's .deb into deb-output/
./container-build.sh avb         # build avb and its dependencies only
./container-build-cross.sh       # cross-compile arm64 .debs (no qemu, no tests)
./container-fuzz.sh              # run the libFuzzer campaigns (crypto, avb)
```

### Formatting

```sh
./reformat.sh                    # format all packages in place
./reformat.sh --check           # CI mode: non-zero exit if anything would change
```
