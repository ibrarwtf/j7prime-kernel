#!/bin/bash
# stock-module.sh: rebuild in-tree modules for the stock Nura/postmarketOS kernel
# linux-postmarketos-exynos7870 6.15 (pmaports device/testing/linux-postmarketos-exynos7870/APKBUILD):
#   linux-6.15.tar.gz + every file in mainline-patches@<commit>/patches/* applied in glob order
#   with `patch -p1`, devicetrees/* copied into arch/arm64/boot/dts/exynos, config, LLVM=1.
# env: MODULES (comma list of CONFIG_ symbols), FULL (true/false), BASE_CONFIG, LLVMSUFFIX (e.g. -22)
#      EXPECT_RELEASE, OUT
set -euo pipefail
top=$PWD
KVER=6.15
PCOMMIT=5686e3b545bd34e80ec6e73604b8819d10e52a2c
# sha512sums from the APKBUILD (pkgrel=6)
KSHA=a12a16c08c8867397c69c8eeb5a1a9195253cbcce8d0a9cc731c24d027d79040a9d2b598bcc2c6fca0f4a1f019216e652d2fc1a00025b15c064b7165a61ee9c3
PSHA=6ae251c24451851480a44f754cc1c7d07aef698c177b850c5f45f7018c767803c4609add27e5d9a747140e692180ad76f057e471cf0d3038e05050e40d8ea6db
W=$HOME/stock
mkdir -p "$W" "$OUT"
cd "$W"

curl -fsSL -o linux-$KVER.tar.gz https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KVER.tar.gz
echo "$KSHA  linux-$KVER.tar.gz" | sha512sum -c -
curl -fsSL -o patches.tar.gz "https://gitlab.com/exynos7870-mainline/mainline-patches/-/archive/$PCOMMIT/mainline-patches-$PCOMMIT.tar.gz"
if echo "$PSHA  patches.tar.gz" | sha512sum -c - ; then
	PNOTE="patches tarball sha512 matches the APKBUILD"
else
	# GitLab regenerates archives; the tree content is what matters (commit-pinned URL)
	PNOTE="patches tarball sha512 differs from the APKBUILD (archive regenerated?); content is pinned by commit"
	echo "::warning::$PNOTE"
fi
tar xzf linux-$KVER.tar.gz
tar xzf patches.tar.gz
cd linux-$KVER

n=0
for patchfile in "$W"/mainline-patches-*/patches/*; do
	echo "== $(basename "$patchfile")"
	patch -p1 <"$patchfile" >/dev/null
	n=$((n + 1))
done
echo "applied $n patches"
makefile=arch/arm64/boot/dts/exynos/Makefile
for dts in "$W"/mainline-patches-*/devicetrees/*dts*; do
	[ -e "$dts" ] || continue
	dtb="$(basename "$dts" | sed 's/\.dts$/.dtb/')"
	cp "$dts" arch/arm64/boot/dts/exynos/
	grep -q "$dtb" "$makefile" || echo "dtb-\$(CONFIG_ARCH_EXYNOS) += $dtb" >>"$makefile"
done

mk() { make -j"$(nproc)" ARCH=arm64 LLVM="$LLVMSUFFIX" CC="ccache clang$LLVMSUFFIX" "$@"; }

cp "$top/$BASE_CONFIG" .config
: >"$W/requested.txt"
for sym in ${MODULES//,/ }; do
	s=${sym#CONFIG_}
	[[ $s =~ ^[A-Z0-9_]+$ ]] || { echo "::error::bad symbol $sym"; exit 1; }
	./scripts/config --module "$s"
	echo "CONFIG_$s=m" >>"$W/requested.txt"
done
mk olddefconfig
bash "$top/scripts/check-config.sh" "$W/requested.txt" .config
echo "--- config changes vs $BASE_CONFIG (compiler-version symbols are expected):"
diff <(grep -v '^#' "$top/$BASE_CONFIG" | sort) <(grep -v '^#' .config | sort) || true

rel=$(mk -s kernelrelease)
echo "kernelrelease: $rel"
[ "$rel" = "$EXPECT_RELEASE" ] || { echo "::error::kernelrelease '$rel' != '$EXPECT_RELEASE'"; exit 1; }

# expected vermagic, derived from the config exactly like include/linux/vermagic.h
c() { grep -q "^CONFIG_$1=y" .config; }
vm="$rel "
c SMP && vm+="SMP "
if c PREEMPT_RT; then vm+="preempt_rt "; elif c PREEMPT_BUILD; then vm+="preempt "; fi
c MODULE_UNLOAD && vm+="mod_unload "
c MODVERSIONS && vm+="modversions "
vm+="aarch64"
c RANDSTRUCT_NONE || vm+=" RANDSTRUCT_?"   # stock has RANDSTRUCT_NONE; anything else needs the seed hash
echo "expected vermagic: $vm"

dirs=() kos=()
for sym in ${MODULES//,/ }; do
	s=${sym#CONFIG_}
	hit=$(grep -rnE --include=Makefile --include=Kbuild "^obj-\\\$\(CONFIG_${s}\)[[:space:]]*[+:]?=" . | head -1 || true)
	[ -n "$hit" ] || { echo "::error::no Makefile line for CONFIG_$s"; exit 1; }
	f=${hit%%:*}
	d=$(dirname "${f#./}")
	objs=$(echo "${hit#*=}" | grep -oE '[A-Za-z0-9_-]+\.o' || true)
	[ -n "$objs" ] || { echo "::error::CONFIG_$s does not map to a single-object module ($hit); use full=true"; exit 1; }
	dirs+=("$d")
	for o in $objs; do kos+=("$d/${o%.o}.ko"); done
	echo "CONFIG_$s -> $d: $objs"
done

if [ "$FULL" = true ]; then
	mk modules
else
	mk modules_prepare
	for d in $(printf '%s\n' "${dirs[@]}" | sort -u); do
		KBUILD_MODPOST_WARN=1 mk M="$d" modules
	done
fi
ccache -s | tail -6 || true

fail=0
: >"$OUT/modinfo.txt"
for ko in "${kos[@]}"; do
	b=$(basename "$ko")
	[ -f "$ko" ] || { echo "::error::$ko was not built"; fail=1; continue; }
	cp "$ko" "$OUT/$b"
	llvm-strip$LLVMSUFFIX --strip-debug "$OUT/$b"          # = INSTALL_MOD_STRIP=1
	zstd -q -19 -f "$OUT/$b" -o "$OUT/$b.zst"              # stock installs modules as .ko.zst
	{ echo "== $b"; modinfo "$OUT/$b" || strings "$OUT/$b" | grep -E '^(vermagic|name|depends|license|alias)='; echo; } >>"$OUT/modinfo.txt"
	got=$(strings "$OUT/$b" | sed -n 's/^vermagic=//p' | head -1 | sed 's/[[:space:]]*$//')
	echo "$b vermagic: '$got'"
	if [ "$got" != "$vm" ]; then echo "::error::$b vermagic '$got' != expected '$vm'"; fail=1; fi
	echo "| $b | \`$got\` | $(stat -c %s "$OUT/$b") |" >>"$W/rows.md"
done
cat "$OUT/modinfo.txt"
cp .config "$OUT/config"
echo "$rel" >"$OUT/release.txt"
{
	echo "linux-$KVER.tar.gz (sha512 verified) + exynos7870-mainline/mainline-patches@$PCOMMIT ($n patches, glob order, patch -p1)"
	echo "$PNOTE"
	echo "recipe: pmaports device/testing/linux-postmarketos-exynos7870/APKBUILD pkgver=6.15 pkgrel=6"
	echo "compiler: $(clang$LLVMSUFFIX --version | head -1)"
	echo "mode: $([ "$FULL" = true ] && echo 'full make modules' || echo 'modules_prepare + make M=<dir> (no Module.symvers; depends= may be empty)')"
	echo "expected vermagic: $vm"
} | tee "$OUT/source.txt"
echo "$vm" >"$W/vermagic.txt"
exit $fail
