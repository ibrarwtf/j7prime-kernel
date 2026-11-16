#!/bin/bash
# check-config.sh <requested> <.config>
# Every "CONFIG_X=v" / "# CONFIG_X is not set" line in <requested> must be
# present with the same value in the final <.config>. Prints each mismatch and
# exits 1 if there is any (merge_config.sh/olddefconfig only warn).
set -u
req=$1 cfg=$2
fail=0 n=0
while IFS= read -r line || [ -n "$line" ]; do
	line=${line%$'\r'}
	case "$line" in
	CONFIG_*=*) sym=${line%%=*}; want=${line#*=} ;;
	"# CONFIG_"*" is not set") sym=${line#\# }; sym=${sym%% *}; want=n ;;
	*) continue ;;
	esac
	n=$((n + 1))
	got=$(grep -E "^${sym}=" "$cfg" | tail -1 | cut -d= -f2-)
	[ -z "$got" ] && got=n
	if [ "$want" != "$got" ]; then
		echo "::error title=config mismatch::${sym}: requested ${want}, got ${got} (unmet dependency or invalid symbol)"
		fail=1
	fi
done <"$req"
if [ $fail = 0 ]; then
	echo "check-config: all $n requested symbols present in final .config"
fi
exit $fail
