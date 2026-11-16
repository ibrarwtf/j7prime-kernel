# j7prime-kernel

Kernel build recipes for the **Samsung Galaxy J7 Prime (SM-G610F, `on7xelte`, Exynos 7870)** running Nura / postmarketOS, built on GitHub Actions.

One workflow, `kernel` (`.github/workflows/kernel.yml`), selected with the `mode` input:

| mode | what it does | artifact |
|---|---|---|
| `kernel` (default) | fetches `repo`@`ref`, applies each build id, builds `Image`, modules and the on7xelte DTBs (gcc + ccache, ~20 min cold); then a QEMU `virt` smoke test | `kernel-<id>`: `Image`, DTBs, `modules.tgz`, `config`, `release.txt`, `source.txt`, `SHA256SUMS` |
| `stock-module` | rebuilds the stock Nura kernel tree (linux 6.15 + `exynos7870-mainline/mainline-patches@5686e3b5`, applied like the pmaports `linux-postmarketos-exynos7870` APKBUILD, clang/LLVM) with `kernel/base-6.15.config`, checks `kernelrelease` = `6.15.0-exynos7870`, builds the requested in-tree modules and verifies their `vermagic` | `stock-modules-6.15.0-exynos7870`: `*.ko`, `*.ko.zst`, `modinfo.txt`, `config`, `SHA256SUMS` |
| `stable` | rebuilds the pmaports `linux-postmarketos-stable` 7.3.4 recipe (linux-7.3 + patch-7.3.4 + the package patches, `config-stable.aarch64`, sha512-checked against the pinned APKBUILD, `LLVM=1` in an Alpine edge container on a native arm64 runner), then applies `patches/7.3.4/*.patch` and `<build_dir>/<id>.fragment`; fails fast on the on7xelte DTB and the added drivers before the full build | `kernel-<id>` (kept 3 days): raw `Image`, `exynos7870-on7xelte.dtb` (+ decompiled), `modules.tar`, `config`, `config.diff`, `release.txt`, `source.txt`, `SHA256SUMS` |
| `dtb` | device trees only (same build-id convention), plus decompiled `.dts` and a non-fatal `dtbs_check` (warnings in the job summary) | `dtb-<id>` |

Inputs: `builds` (comma-separated, one matrix job each), `repo` + `ref` (any branch, tag or commit; default `exynos7870-mainline/linux` `exynos7870/7.1`), `base_config` (a file under `kernel/`), `build_dir` (default `kernel/7.1`), `modules` (stock-module: config symbols, default `CONFIG_I2C_CHARDEV`), `full_modules` (stock-module: full `make modules` instead of `modules_prepare` + per-directory build), `qemu`, `release` (default off: publish a GitHub release `<id>-<run_number>` with the same files).

## Adding a build

Create in `kernel/7.1/` (or another `build_dir`):
- `<id>.fragment`: config lines merged onto the base config. **Every line must survive `olddefconfig`**; the job fails and lists symbols whose value changed (missing dependency, typo).
- `on7xelte-<id>.dtsi` (optional): appended to `arch/arm64/boot/dts/exynos/exynos7870-on7xelte.dts`.
- `patches/<id>/*.patch` (optional): applied with `git apply`.

If the tree has `i2c@13870000`, an extra `exynos7870-on7xelte-bus.dtb` (that bus enabled, no client) is produced for debugging.

### Build p1 (7.3.4, `kernel/7.3.4/p1.fragment`)
Upstream v7.3.4 + the postmarketOS stable config with only: `LOCALVERSION=-j7p1`, `PSTORE_RAM/CONSOLE/PMSG=y`, lockdown not forced (`LOCK_DOWN_KERNEL_FORCE_NONE`, `MODULE_SIG_FORCE` off), `PANIC_TIMEOUT=10`, the standalone S2MU005 fuel gauge (`s2mu005_fg`) and MIP4 touch key (`mip4_touchkey`) drivers as modules (ported from exynos7870-mainline/mainline-patches, see the patch headers), and the upstream S2MU005 charger/MUIC/LED/fuel-gauge drivers off. The DT patch adds the watchdog, a bit-banged I2C bus on the S2MU005 pins (no client), the fuel gauge and touch key buses.

```sh
gh workflow run kernel.yml -f mode=stable -f builds=p1 -f build_dir=kernel/7.3.4
```

### Build p2 (7.3.4, `kernel/7.3.4/p2.fragment`)
p1 + CPU temperature, frequency scaling and idle for the Exynos 7870 (`patches/7.3.4/0004`-`0015`, `0018`): the TMU driver and node with one SoC thermal zone (passive 80/90 °C, hot 100 °C, critical 110 °C), CMU_CPUCL0/1 + the clk-cpu layout, cpufreq-dt with one OPP table per cluster on BUCK1 (546-1248 MHz; 1352/1482/1586 MHz present but disabled), the PSCI core power-down state registered switched off (`cpuidle_psci.exynos7870_deep_idle=1` registers it enabled), the PMU core-configuration notifier. `0014` configures the Wi-Fi host-wake pin (EINT + pull-up; without it the out-of-band interrupt fired ~18000 times/s), `0018` runs the eMMC at HS200 (137.9 MB/s sequential read instead of 21.6), `0015` keeps BUCK1 at or above the bootloader's 737.5 mV (shared rail: a cluster has no voltage request before its first frequency change). The ramoops region is 256 KiB (dmesg 16 KiB + console 224 KiB + pmsg 16 KiB). `LOCALVERSION=-j7p2`.

```sh
gh workflow run kernel.yml -f mode=stable -f builds=p2 -f build_dir=kernel/7.3.4
```

`p2l` (`kernel/7.3.4/p2l.fragment`) = p2 + the standalone S2MU005 charger/RGB LED driver (`0016`-`0017`) as a module, same release name, for loading by hand; no DT client node, so nothing loads it automatically.

## Running and downloading

```sh
gh workflow run kernel.yml -f mode=kernel -f builds=b1
gh workflow run kernel.yml -f mode=dtb -f builds=b1,b2
gh workflow run kernel.yml -f mode=stock-module -f modules=CONFIG_I2C_CHARDEV
gh workflow run kernel.yml -f builds=b1 -f repo=https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git -f ref=v6.18.5
gh run list -w kernel -L 5
gh run download <run-id> -n kernel-b1
```

With `release=true` a device can fetch files with plain `curl -LO https://github.com/<owner>/j7prime-kernel/releases/download/<tag>/<file>`.

The QEMU smoke test boots `Image` on `qemu-system-aarch64 -M virt -cpu cortex-a53` with a one-file static `/init` that prints a marker and powers off. The phone config has no PL011/virtio console and is not changed for the test; instead QEMU pauses on the guest power-off/reset/panic (or at the 180 s timeout), the guest RAM is saved over QMP and searched for the marker (built at run time by `/init`, so it can only exist if init ran); kernel-log fragments found in RAM are printed for diagnosis. It only proves the kernel reaches userspace on generic arm64; it says nothing about phone drivers.

Tested only on our own device, via `kexec -c` with the hardware watchdog armed. Use at your own risk.

Credits / prior work: exynos7870-mainline (Kaustabh Chakraborty), Alessandro Fontana (`linux-exynos7870`), Burak (`j701f-linux`), Martin Štrobl (`a3y17lte-mainline`), the postmarketOS/Nura community.

License: kernel configs, DT fragments and patches are GPL-2.0 (like the kernel); workflow and scripts MIT. This is a personal experiment and not a contribution to Nura/postmarketOS.
