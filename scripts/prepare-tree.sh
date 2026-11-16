#!/bin/bash
# prepare-tree.sh: fetch a kernel tree and apply one build id.
# env: REPO REF BUILD BUILD_DIR BASE_CONFIG SRC (output dir) ; ARCH/CROSS_COMPILE set by caller
# Build id <b> = $BUILD_DIR/<b>.fragment + $BUILD_DIR/on7xelte-<b>.dtsi + optional $BUILD_DIR/patches/<b>/*.patch
set -euo pipefail
top=$PWD
frag="$top/$BUILD_DIR/$BUILD.fragment"
dtsi="$top/$BUILD_DIR/on7xelte-$BUILD.dtsi"
[ -f "$top/$BASE_CONFIG" ] || { echo "::error::base config $BASE_CONFIG not found"; exit 1; }
[ -f "$frag" ] || { echo "::error::$BUILD_DIR/$BUILD.fragment not found"; exit 1; }

# shallow fetch of a branch, tag or commit
git init -q "$SRC"
git -C "$SRC" remote add origin "$REPO"
git -C "$SRC" fetch -q --depth 1 origin "$REF"
git -C "$SRC" checkout -q FETCH_HEAD
sha=$(git -C "$SRC" rev-parse HEAD)
{
	echo "repo: $REPO"
	echo "ref: $REF"
	echo "commit: $sha"
	echo "subject: $(git -C "$SRC" log -1 --format=%s)"
	echo "build: $BUILD ($BUILD_DIR)"
	echo "base_config: $BASE_CONFIG"
} | tee "$top/source.txt"

cd "$SRC"
for p in "$top/$BUILD_DIR/patches/$BUILD"/*.patch; do
	[ -e "$p" ] || continue
	echo "applying ${p#$top/}"
	git apply --verbose "$p"
done

D=arch/arm64/boot/dts/exynos
[ -f $D/exynos7870-on7xelte.dts ] || { echo "::error::$D/exynos7870-on7xelte.dts does not exist in $REPO@$REF"; exit 1; }
if [ -f "$dtsi" ]; then
	cat "$dtsi" >>$D/exynos7870-on7xelte.dts
else
	echo "::warning::no $BUILD_DIR/on7xelte-$BUILD.dtsi, using the tree's dts unchanged"
fi
# debug variant: S2MU005 i2c bus (i2c@13870000) enabled, no client
DTBS="exynos/exynos7870-on7xelte.dtb"
if grep -q 'i2c@13870000' $D/exynos7870.dtsi 2>/dev/null; then
	cp $D/exynos7870-on7xelte.dts $D/exynos7870-on7xelte-bus.dts
	printf '\n&{/soc@0/i2c@13870000} {\n\tstatus = "okay";\n\tsamsung,i2c-sda-delay = <100>;\n\tsamsung,i2c-max-bus-freq = <400000>;\n};\n' >>$D/exynos7870-on7xelte-bus.dts
	echo 'dtb-$(CONFIG_ARCH_EXYNOS) += exynos7870-on7xelte-bus.dtb' >>$D/Makefile
	DTBS="$DTBS exynos/exynos7870-on7xelte-bus.dtb"
fi
echo "$DTBS" >"$top/dtbs.txt"

cp "$top/$BASE_CONFIG" .config
./scripts/kconfig/merge_config.sh -m .config "$frag"
make olddefconfig
bash "$top/scripts/check-config.sh" "$frag" .config
