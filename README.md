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
