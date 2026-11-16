# j7prime-kernel

Kernel build recipes for the **Samsung Galaxy J7 Prime (SM-G610F, `on7xelte`, Exynos 7870)** running Nura / postmarketOS, built on GitHub Actions.

- Source: [`exynos7870-mainline/linux`](https://gitlab.com/exynos7870-mainline/linux) (branch `exynos7870/7.1` by default).
- `kernel/base-6.15.config`: the Nura `linux-postmarketos-exynos7870` 6.15 config, used as the starting point (`make olddefconfig`).
- `kernel/7.1/<build>.fragment`: config deltas per build; `kernel/7.1/on7xelte-<build>.dtsi`: device-tree additions appended to `exynos7870-on7xelte.dts`; `kernel/7.1/patches/<build>/*.patch`: optional patches.
- Each build also produces `exynos7870-on7xelte-bus.dtb` (i2c@13870000 enabled, no client) for debugging.

Run: Actions → **kernel** → *Run workflow* (`build=b1`). Artifacts: `Image`, DTBs, `modules.tgz`, `config`, `SHA256SUMS`.

Tested only on our own device, via `kexec -c` with the hardware watchdog armed. Use at your own risk.

Credits / prior work: exynos7870-mainline (Kaustabh Chakraborty), Alessandro Fontana (`linux-exynos7870`), Burak (`j701f-linux`), Martin Štrobl (`a3y17lte-mainline`), the postmarketOS/Nura community.

License: kernel configs, DT fragments and patches are GPL-2.0 (like the kernel); workflow and scripts MIT. This is a personal experiment and not a contribution to Nura/postmarketOS.
