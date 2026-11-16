#!/bin/bash
# p2-build.sh: compile test of the p2 series (Exynos 7870 TMU + cpufreq + cpuidle) on 7.3.4.
# Base = pmaports linux-postmarketos-stable 7.3.4 recipe: linux-7.3.tar.xz + patch-7.3.4 +
# the package's patches + config-stable.aarch64, built with clang/LLVM (cross, ARCH=arm64).
# On top: patches/7.3.4-p2/*.patch (strict, no fuzz) and kernel/7.3.4-p2/p2.fragment.
# env: OUT (absolute) ; optional FULL=true (also package modules), LLVM_SUFFIX (e.g. -21)
set -euo pipefail
top=$(pwd)
KVER=7.3.4
KBASE=7.3
PATCHDIR="$top/patches/7.3.4-p2"
FRAG="$top/kernel/7.3.4-p2/p2.fragment"
PMAPORTS=https://gitlab.nura.eco/api/v4/projects/226/repository/files   # = postmarketOS/pmaports (Nura mirror)
PMAPORTS_COMMIT=${PMAPORTS_COMMIT:-f86f71a06a2ceab7ba995f331d2fd858cd623893}  # "linux-postmarketos-stable: Upgrade to 7.3.4"
PKGDIR=device%2Fmain%2Flinux-postmarketos-stable
DTB=exynos/exynos7870-on7xelte.dtb
W=$HOME/p2
mkdir -p "$W" "$OUT"
cd "$W"

get_pm() { curl -fsSL --retry 3 -o "$1" "$PMAPORTS/$PKGDIR%2F$1/raw?ref=$PMAPORTS_COMMIT"; }
get_pm APKBUILD
grep -q "^pkgver=$KVER$" APKBUILD || { echo "::error::APKBUILD@$PMAPORTS_COMMIT is not $KVER"; exit 1; }
pkgrel=$(sed -n 's/^pkgrel=//p' APKBUILD)
sed -n '/^sha512sums="/,/^"/p' APKBUILD | grep -E '^[0-9a-f]{128}  ' >sums.txt
srcpatches=$(sed -n '/^source="/,/^"/p' APKBUILD | grep -oE '[0-9]{4}-[^ ]+\.patch' || true)
for f in $srcpatches config-stable.aarch64; do get_pm "$f"; done
[ -f linux-$KBASE.tar.xz ] || curl -fsSL --retry 3 -o linux-$KBASE.tar.xz https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-$KBASE.tar.xz
[ -f patch-$KVER.patch.xz ] || curl -fsSL --retry 3 -o patch-$KVER.patch.xz https://cdn.kernel.org/pub/linux/kernel/v7.x/patch-$KVER.xz
for f in linux-$KBASE.tar.xz patch-$KVER.patch.xz $srcpatches config-stable.aarch64; do
	grep "  $f\$" sums.txt | sha512sum -c - || { echo "::error::sha512 mismatch for $f"; exit 1; }
done

rm -rf linux-$KBASE
tar xJf linux-$KBASE.tar.xz
cd linux-$KBASE
xz -dc ../patch-$KVER.patch.xz | patch -p1 -s
for p in $srcpatches; do echo "== pmaports $p"; patch -p1 -s <"../$p"; done
n=0
for p in "$PATCHDIR"/*.patch; do
	echo "== ${p#$top/}"
	patch -p1 -F0 --no-backup-if-mismatch <"$p"
	n=$((n + 1))
done
echo "applied $n p2 patches"
# patch(1) leaves .rej/.orig only on failure, which already stopped the script
[ -z "$(find . -name '*.rej' -o -name '*.orig' | head -1)" ]

mk() { make -j"$(nproc)" ARCH=arm64 LLVM="${LLVM_SUFFIX:-1}" CC="ccache clang${LLVM_SUFFIX:-}" KBUILD_BUILD_VERSION="$((pkgrel + 1))-p2" "$@"; }

cp ../config-stable.aarch64 .config
./scripts/kconfig/merge_config.sh -m .config "$FRAG" >/dev/null
mk olddefconfig >/dev/null
bash "$top/scripts/check-config.sh" "$FRAG" .config
diff ../config-stable.aarch64 .config | grep '^[<>]' | grep -v '^[<>] #$' >"$OUT/config.diff" || true
echo "--- config changes vs config-stable.aarch64 (toolchain symbols expected):"
cat "$OUT/config.diff"

rel=$(mk -s kernelrelease)
echo "kernelrelease: $rel"

# 1) fast checks first: the DTB and the touched objects, with W=1
mk $DTB
objs="drivers/thermal/samsung/exynos_tmu.o drivers/clk/samsung/clk-exynos7870.o
      drivers/clk/samsung/clk-cpu.o drivers/soc/samsung/exynos-pmu.o
      drivers/soc/samsung/exynos7870-pmu.o drivers/cpuidle/cpuidle-psci.o"
mk W=1 $objs 2>&1 | tee "$OUT/w1.log"
if grep -E 'warning:|error:' "$OUT/w1.log"; then
	echo "::error::W=1 warnings in the touched files (see w1.log)"
	exit 1
fi
mk W=1 $DTB 2>&1 | tee "$OUT/dtb-w1.log"
grep -E 'Warning|warning' "$OUT/dtb-w1.log" && echo "::warning::dtc W=1 warnings (see dtb-w1.log)" || true
echo "fast checks OK at $(date -u +%H:%M:%S)"

# 2) dtbs_check for the on7xelte DTB and the two touched bindings (needs dtschema)
if command -v dt-validate >/dev/null; then
	mk dt_binding_check DT_SCHEMA_FILES="samsung,exynos-thermal.yaml:samsung,exynos7870-cmu.yaml" \
		2>&1 | tee "$OUT/dt_binding_check.log" | tail -20 || true
	mk CHECK_DTBS=y $DTB 2>&1 | tee "$OUT/dtbs_check.log" || true
	# messages about nodes this series adds or changes
	grep -E 'cpu@|opp-table|thermal|tmu|cpucl|idle-state|cpu-sleep|buck1' "$OUT/dtbs_check.log" \
		>"$OUT/dtbs_check.p2.log" || true
	echo "--- dtbs_check lines for p2 nodes:"; cat "$OUT/dtbs_check.p2.log"
	[ -s "$OUT/dtbs_check.p2.log" ] && echo "::warning::dtbs_check messages for p2 nodes (dtbs_check.p2.log)"
else
	echo "::warning::dtschema not installed, dtbs_check skipped"
fi

# 3) the full build
mk Image modules
ccache -s | tail -8 || true

cp arch/arm64/boot/Image "$OUT/Image"
gzip -9 -k -c arch/arm64/boot/Image >"$OUT/Image.gz"
rm "$OUT/Image"
cp arch/arm64/boot/dts/$DTB "$OUT/"
scripts/dtc/dtc -q -I dtb -O dts -o "$OUT/exynos7870-on7xelte.decompiled.dts" arch/arm64/boot/dts/$DTB
cp .config "$OUT/config"
cp System.map "$OUT/" 2>/dev/null || true
echo "$rel" >"$OUT/release.txt"
if [ "${FULL:-false}" = true ]; then
	mkdir -p "$W/mod"
	mk -s modules_install INSTALL_MOD_PATH="$W/mod" INSTALL_MOD_STRIP=1
	rm -f "$W"/mod/lib/modules/*/build "$W"/mod/lib/modules/*/source
	tar -C "$W/mod" -cf - lib | zstd -19 -T0 >"$OUT/modules.tar.zst"
	rm -rf "$W/mod"
fi
{
	echo "linux-$KBASE.tar.xz + patch-$KVER (sha512 from the APKBUILD) + pmaports patches: $srcpatches"
	echo "recipe: pmaports device/main/linux-postmarketos-stable/APKBUILD pkgver=$KVER pkgrel=$pkgrel @ $PMAPORTS_COMMIT"
	echo "config: config-stable.aarch64 @ $PMAPORTS_COMMIT + kernel/7.3.4-p2/p2.fragment"
	echo "p2 patches: $(cd "$PATCHDIR" && ls *.patch | tr '\n' ' ')"
	echo "compiler: $(clang${LLVM_SUFFIX:-} --version | head -1)"
	echo "kernelrelease: $rel"
} | tee "$OUT/source.txt"
