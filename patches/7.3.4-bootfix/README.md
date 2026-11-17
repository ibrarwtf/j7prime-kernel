# Boot-reliability patches for 7.3.4 on the SM-G610F (on7xelte)

Not applied by any build: this directory is outside `patches/7.3.4/`. Base: linux v7.3.4 + `patches/7.3.4/0001-0017`.
All three apply with `patch -p1 -F0` (checked on a mini tree of the touched files); not compiled yet.

| patch | kind | what | status |
|---|---|---|---|
| 0001 ramoops ECC | DT only | `ecc-size = <16>` on the ramoops node: a few DRAM bits in the ramoops region flip across resets (fixed bit positions, seen on many boots), which makes ramoops discard whole zones; ECC corrects them and counts them | ready; can also be made on the phone from a DTB with `fdtput -t i <dtb> /reserved-memory/ramoops@46e00000 ecc-size 16` |
| 0002 mmc: CMD0 on restart | driver | opt-in per host: a restart (not a power-off) ends with legacy timing + CMD0 instead of a power-off notification, because the eMMC supplies stay on and RST_n is disabled | experiment for the boot-failure test plan |
| 0003 on7xelte: opt in | DT | `mmc-go-idle-on-restart;` in `&mmc0` (ignored without 0002) | goes with 0002 |

Context: boots that failed before the kernel ran, seen only after clean restarts from kernels that ran the eMMC at
DDR52 (2 of 6), never after ~45 restarts at legacy timing. Root cause not proven; see the test plan in the
private results file.
