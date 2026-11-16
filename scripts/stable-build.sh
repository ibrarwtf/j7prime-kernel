#!/bin/sh
# stable-build.sh: rebuild pmaports linux-postmarketos-stable (generic arm64 kernel) exactly like its
# APKBUILD (linux-7.3.tar.xz + patch-7.3.4.xz + the package's patches, config-stable.aarch64,
# make LLVM=1), then apply our build id on top:
#   patches/<kver>/*.patch  (patch -p1, in glob order)  and  <BUILD_DIR>/<BUILD>.fragment
# Runs inside an Alpine container on a native arm64 runner (same toolchain family as the package).
# env: BUILD BUILD_DIR OUT (absolute) ; optional PMAPORTS_COMMIT
set -eu
top=$(pwd)
KVER=7.3.4
KBASE=7.3
PMAPORTS=https://gitlab.nura.eco/api/v4/projects/226/repository/files   # = postmarketOS/pmaports (Nura mirror)
PMAPORTS_COMMIT=${PMAPORTS_COMMIT:-f86f71a06a2ceab7ba995f331d2fd858cd623893}  # "linux-postmarketos-stable: Upgrade to 7.3.4"
PKGDIR=device%2Fmain%2Flinux-postmarketos-stable
frag="$top/$BUILD_DIR/$BUILD.fragment"
[ -f "$frag" ] || { echo "::error::$BUILD_DIR/$BUILD.fragment not found"; exit 1; }
W=$HOME/stable
mkdir -p "$W" "$OUT"
cd "$W"

get_pm() { curl -fsSL -o "$1" "$PMAPORTS/$PKGDIR%2F$1/raw?ref=$PMAPORTS_COMMIT"; }
get_pm APKBUILD
grep -q "^pkgver=$KVER$" APKBUILD || { echo "::error::APKBUILD@$PMAPORTS_COMMIT is not $KVER"; exit 1; }
pkgrel=$(sed -n 's/^pkgrel=//p' APKBUILD)
# sha512sums block of the APKBUILD -> file list for sha512sum -c
sed -n '/^sha512sums="/,/^"/p' APKBUILD | grep -E '^[0-9a-f]{128}  ' >sums.txt
srcpatches=$(sed -n '/^source="/,/^"/p' APKBUILD | grep -oE '[0-9]{4}-[^ ]+\.patch' || true)
for f in $srcpatches config-stable.aarch64; do get_pm "$f"; done
curl -fsSL -o linux-$KBASE.tar.xz https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-$KBASE.tar.xz
curl -fsSL -o patch-$KVER.patch.xz https://cdn.kernel.org/pub/linux/kernel/v7.x/patch-$KVER.xz
for f in linux-$KBASE.tar.xz patch-$KVER.patch.xz $srcpatches config-stable.aarch64; do
	grep "  $f\$" sums.txt | sha512sum -c - || { echo "::error::sha512 mismatch for $f"; exit 1; }
done

rm -rf linux-$KBASE
tar xJf linux-$KBASE.tar.xz
cd linux-$KBASE
xz -dc ../patch-$KVER.patch.xz | patch -p1 -s
for p in $srcpatches; do echo "== pmaports $p"; patch -p1 -s <"../$p"; done
n=0
for p in "$top"/patches/$KVER/*.patch; do
	[ -e "$p" ] || continue
	echo "== ${p#$top/}"
	patch -p1 --no-backup-if-mismatch <"$p"
	n=$((n + 1))
done
echo "applied $n j7prime patches"

mk() { make -j"$(nproc)" ARCH=arm64 LLVM=1 CC="ccache clang" KBUILD_BUILD_VERSION="$((pkgrel + 1))-$BUILD" "$@"; }

cp ../config-stable.aarch64 .config
./scripts/kconfig/merge_config.sh -m .config "$frag" >/dev/null
mk olddefconfig
# Trimmed builds: a fragment with a "# j7-trim: lsmod=<file> [drop=<file>]" line (files next to it) is built
# from a small config: base + fragment, then the drop fragment (best effort, not asserted), then
# localmodconfig against the captured lsmod of the phone (every =m not loaded there goes), then the fragment
# again (its keep-list wins). Fragments without that line (p1, p2, ...) are built exactly as before.
trim=$(sed -n 's/^# j7-trim: //p' "$frag" | head -1)
if [ -n "$trim" ]; then
	tlsmod= tdrop=
	for kv in $trim; do
		case $kv in lsmod=*) tlsmod=$top/$BUILD_DIR/${kv#lsmod=} ;; drop=*) tdrop=$top/$BUILD_DIR/${kv#drop=} ;; esac
	done
	[ -f "$tlsmod" ] || { echo "::error::j7-trim: lsmod file '$tlsmod' not found"; exit 1; }
	echo "--- j7-trim: $(grep -c '=[ym]$' .config) options set before trimming"
	if [ -n "$tdrop" ]; then
		[ -f "$tdrop" ] || { echo "::error::j7-trim: drop file '$tdrop' not found"; exit 1; }
		./scripts/kconfig/merge_config.sh -m .config "$tdrop" >/dev/null
		mk olddefconfig
	fi
	# streamline_config.pl *executes* an LSMOD file that has the x bit: always hand it a plain copy
	cp "$tlsmod" ../lsmod.txt && chmod 644 ../lsmod.txt
	yes '' | mk LSMOD="$(pwd)/../lsmod.txt" localmodconfig >"$OUT/localmodconfig.log" 2>&1 || { tail -20 "$OUT/localmodconfig.log"; exit 1; }
	./scripts/kconfig/merge_config.sh -m .config "$frag" >/dev/null
	mk olddefconfig
	echo "--- j7-trim: $(grep -c '=y$' .config) =y, $(grep -c '=m$' .config) =m after trimming"
fi
bash "$top/scripts/check-config.sh" "$frag" .config
echo "--- config changes vs config-stable.aarch64 (toolchain version symbols are expected):"
diff ../config-stable.aarch64 .config | grep '^[<>]' | grep -v '^[<>] #$' | tee "$OUT/config.diff" || true

# safety: the S2MU005 function drivers must be off; show what can match an S2MU005 node
echo "--- S2MU005 symbols in the final config:"
grep -E 'S2MU|S2M_|_S2M=|EXTCON_S2M' .config || true
echo "--- S2MU005 compatibles in built-in/module sources:"
grep -rn --include=*.c 's2mu005' drivers/mfd drivers/power drivers/extcon drivers/leds | grep -E 'compatible|of_device_id' || true

rel=$(mk -s kernelrelease)
echo "kernelrelease: $rel"
case "$rel" in *-"$BUILD"*|*-j7"$BUILD"*) ;; *) echo "::warning::kernelrelease '$rel' does not carry the build id";; esac

# fail fast: the DTB and our two drivers before the long build
mk exynos/exynos7870-on7xelte.dtb
mk drivers/power/supply/s2mu005_fg.o drivers/input/keyboard/mip4_touchkey.o
echo "fast checks OK at $(date -u +%H:%M:%S)"

mk Image modules
ccache -s | tail -8 || true

mkdir -p "$OUT/mod"
mk -s modules_install INSTALL_MOD_PATH="$OUT/mod" INSTALL_MOD_STRIP=1
rm -f "$OUT"/mod/lib/modules/*/build "$OUT"/mod/lib/modules/*/source
tar -C "$OUT/mod" -cf "$OUT/modules.tar" lib
du -sh "$OUT/mod" "$OUT/modules.tar"
rm -rf "$OUT/mod"
cp arch/arm64/boot/Image "$OUT/Image"
cp arch/arm64/boot/dts/exynos/exynos7870-on7xelte.dtb "$OUT/"
scripts/dtc/dtc -q -I dtb -O dts -o "$OUT/exynos7870-on7xelte.decompiled.dts" arch/arm64/boot/dts/exynos/exynos7870-on7xelte.dtb
cp .config "$OUT/config"
echo "$rel" >"$OUT/release.txt"
{
	echo "linux-$KBASE.tar.xz + patch-$KVER (sha512 from the APKBUILD) + pmaports patches: $srcpatches"
	echo "recipe: pmaports device/main/linux-postmarketos-stable/APKBUILD pkgver=$KVER pkgrel=$pkgrel @ $PMAPORTS_COMMIT"
	echo "base config: config-stable.aarch64 @ $PMAPORTS_COMMIT + $BUILD_DIR/$BUILD.fragment"
	echo "j7prime patches: $(cd "$top" && ls patches/$KVER/*.patch | tr '\n' ' ')"
	echo "compiler: $(clang --version | head -1); rustc: $(rustc --version 2>/dev/null || echo none)"
	echo "kernelrelease: $rel"
	echo "objects: $(find . -name '*.o' | wc -l), modules: $(find . -name '*.ko' | wc -l)"
} | tee "$OUT/source.txt"
