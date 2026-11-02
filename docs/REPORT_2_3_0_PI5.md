<!-- Copyright 2026 Jeff Koftinoff <jeff.koftinoff@statusbar.com> -->
<!-- SPDX-License-Identifier: MIT -->

# statusbar 2.3.0 on the Raspberry Pi 5 rig

The umbrella's view of the 2.3.0 work: what changed at this level, how the
packages were built and deployed to the Raspberry Pi 5 nodes, and where the
per-repository reports are.

- `core/docs/REPORT_2_3_0_PI5.md` — the runtime Ethernet port, AF_XDP
  ownership and counters, launch time and the qdiscs under it, and the core
  test results on the Pi.
- `avb/docs/REPORT_2_3_0_PI5.md` — the entity stream port, presentation
  margin timing, the TX kicker, and the pair measurements.

## What changed in the umbrella itself

- **Pre-commit gate for the block-statements house rule.** `install-hooks.sh`
  installs a hook that runs core's `check-block-statements.sh` on the staged
  C++ of the committing repository, with the gate's path written into each
  hook. Only a flagged block whose lines the change touches fails; an
  exception needs a reason on the brace line.
- **`rtkernel` 1.0-2.** The realtime kernel package for the Pi 5 now builds
  with `CONFIG_XDP_SOCKETS=y` and the CBS, ETF and TAPRIO qdiscs as modules.
  Package 1.0-1 had the same `uname` and no AF_XDP, which cost a day: check
  `CONFIG_XDP_SOCKETS` in `/boot/config-*` before blaming the socket code.
- **Submodule pointers** follow core and avb through the integration branch
  (launch time and ETF, XDP ownership, the review fixes) to 2.3.0 and the
  pre-mirror fixes.

## The rig

| Node        | Role                                                                   |
|-------------|------------------------------------------------------------------------|
| Pi A, Pi D  | The Linux-to-Linux test pair, each on a port of a MOTU AVB switch      |
| Pi F        | Local test box: ssh over Wi-Fi plus a direct Thunderbolt AVB link to a Mac; runs the tone-generator service; root-only tests run here |
| Pi B, Pi C  | Reached through tunnels; Pi C runs the widget bridge and the device proxies |

All five are Raspberry Pi 5 Model B boards on the `rtkernel`
`6.12.90-nohzfull-rt+` 1.0-2 kernel, booted with
`isolcpus=2-3 nohz_full=2-3 rcu_nocbs=2-3 irqaffinity=0-1`. The on-board
Ethernet is the RP1's `macb`: XDP generic mode with copy, no zero-copy, no
launch-time offload, and a quirk worth knowing: hardware and software TX
timestamps are silently dropped for frames under 60 bytes, so anything that
wants a TX timestamp pads to 60.

## Build and deploy

Packages are cross-compiled for arm64 on a Mac in a podman container:

```
export STATUSBAR_DEB_REVISION=$(date -u +%Y%m%d%H%M%S)
bash core/scripts/container-build-cross.sh      # first, when core changed
bash avb/scripts/container-build-cross.sh
```

Every package is statically linked, so a core-only upgrade needs no daemon
restart; an avb upgrade stops the tone-generator unit on Pi F, which the
postinst now restarts. Old revisions are moved out of `deb-output/` before a
rebuild, because the dependency resolver will otherwise pick a stale sibling.

The x86 CI host builds and unit-tests every `ci/<name>` branch and lands it
on `main`; root-only tests skip there and say so. For the tests that need a
kernel, the arm64 test binary is cross-built the same way, copied to Pi F,
and run as root:

```
sudo ./statusbar_test -A                      # every section
sudo ./statusbar_test statusbar/net/net_linux_xdp_test
```

## What was verified where, 2026-11-01 to 2026-11-02

| What                                             | Where       | Result                                                     |
|--------------------------------------------------|-------------|------------------------------------------------------------|
| core, every test section as root                 | Pi F        | 81 sections, 0 failures                                    |
| core XDP integration suite                       | Pi F        | 119/119 as root; the pinned-replacement path also with `CAP_SYS_ADMIN` dropped |
| core launch-time qdisc sequencing                | recorder, CI | request sequences asserted; `macb` cannot offload etf     |
| avb backends (rawnet, mmap, xdp) TX and RX       | Pi F + Mac  | 8,514 frames/s TX each; 104,000/104,000 RX, 0 seq errors   |
| avb pair, six streams both ways                  | Pi A ↔ Pi D | locked, 0 sequence mismatches, 0 late frames with the RT RX timer, media tick ~6 µs with the kick off the media thread |
| avb tone-generator service on the review build   | Pi F        | healthy, ~8,000 frames/s, bridge up, CRF input connected   |
| bridge and device proxies                        | Pi C        | unchanged suite, untouched by this work                    |

## Deployed at the time of writing

Pi A, Pi D and Pi F run the 2.3.0 core and the avb review-fix build
(revision 20261102062002 over core 20261102052024). Pi C stays on the
previous 2.3.0 suite with its proxies. Pi B is on the 2.1.0 suite. The public
mirrors have not been updated; the pre-mirror review of every private-main
change is complete and the core fixes it asked for are on `main`.

## Open items

- The CRF listener input reports no receive counters (avb report).
- An entity daemon under systemd needs `CAP_BPF` and `CAP_NET_ADMIN` for the
  xdp backend; the tone-generator unit lacks `CAP_BPF`.
- An unpinned daemon that crashes leaves an XDP attachment only
  `CAP_SYS_ADMIN` can identify (core report).
- No 2.3.0 tags exist yet in any repository.
