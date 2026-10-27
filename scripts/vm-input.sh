#!/usr/bin/env bash
# Type text into a libvirt VM, or press named keys, via virsh send-key.
#
#   scripts/vm-input.sh text  "hello World"
#   scripts/vm-input.sh key   KEY_TAB [KEY_ENTER ...]   # each argument pressed in turn
#   scripts/vm-input.sh chord KEY_LEFTALT KEY_N          # pressed together
#   scripts/vm-input.sh click X Y                        # left-click at pixel X,Y
#   scripts/vm-input.sh shot  out.png                    # screenshot
set -euo pipefail

DOMAIN=${DOMAIN:-win7}
URI=${URI:-qemu:///system}
virsh() { command virsh -c "$URI" "$@"; }

send() { virsh send-key "$DOMAIN" --codeset linux "$@" >/dev/null; sleep 0.05; }

keyfor() {
	local c=$1
	case $c in
	[a-z]) echo "KEY_${c^^}" ;;
	[A-Z]) echo "KEY_LEFTSHIFT KEY_$c" ;;
	[0-9]) echo "KEY_$c" ;;
	' ') echo KEY_SPACE ;;
	-) echo KEY_MINUS ;; _) echo "KEY_LEFTSHIFT KEY_MINUS" ;;
	.) echo KEY_DOT ;; ,) echo KEY_COMMA ;;
	/) echo KEY_SLASH ;; '\') echo KEY_BACKSLASH ;;
	:) echo "KEY_LEFTSHIFT KEY_SEMICOLON" ;; ';') echo KEY_SEMICOLON ;;
	=) echo KEY_EQUAL ;; +) echo "KEY_LEFTSHIFT KEY_EQUAL" ;;
	'!') echo "KEY_LEFTSHIFT KEY_1" ;; '@') echo "KEY_LEFTSHIFT KEY_2" ;;
	'#') echo "KEY_LEFTSHIFT KEY_3" ;; '$') echo "KEY_LEFTSHIFT KEY_4" ;;
	'%') echo "KEY_LEFTSHIFT KEY_5" ;; '*') echo "KEY_LEFTSHIFT KEY_8" ;;
	'"') echo "KEY_LEFTSHIFT KEY_APOSTROPHE" ;; "'") echo KEY_APOSTROPHE ;;
	'(') echo "KEY_LEFTSHIFT KEY_9" ;; ')') echo "KEY_LEFTSHIFT KEY_0" ;;
	'[') echo KEY_LEFTBRACE ;; ']') echo KEY_RIGHTBRACE ;;
	'{') echo "KEY_LEFTSHIFT KEY_LEFTBRACE" ;; '}') echo "KEY_LEFTSHIFT KEY_RIGHTBRACE" ;;
	'&') echo "KEY_LEFTSHIFT KEY_7" ;; '|') echo "KEY_LEFTSHIFT KEY_BACKSLASH" ;;
	'<') echo "KEY_LEFTSHIFT KEY_COMMA" ;; '>') echo "KEY_LEFTSHIFT KEY_DOT" ;;
	'?') echo "KEY_LEFTSHIFT KEY_SLASH" ;; '^') echo "KEY_LEFTSHIFT KEY_6" ;;
	'~') echo "KEY_LEFTSHIFT KEY_GRAVE" ;; '`') echo KEY_GRAVE ;;
	*) echo "unsupported char: $c" >&2; exit 1 ;;
	esac
}

case ${1:?usage: vm-type.sh text|key|chord|click|shot ...} in
text)
	s=${2:?text required}
	for ((i = 0; i < ${#s}; i++)); do
		# shellcheck disable=SC2046
		send $(keyfor "${s:i:1}")
	done
	;;
key) shift; for k in "$@"; do send "$k"; done ;;
chord) shift; send "$@" ;;
click)
	# Left-click at screen pixel x y (absolute, via the USB tablet).
	x=${2:?x required} y=${3:?y required}
	tmp=$(mktemp --suffix=.ppm)
	virsh screenshot "$DOMAIN" "$tmp" >/dev/null
	read -r w h < <(magick identify -format '%w %h\n' "$tmp")
	rm -f "$tmp"
	ax=$((x * 32767 / (w - 1))) ay=$((y * 32767 / (h - 1)))
	ev() { virsh qemu-monitor-command "$DOMAIN" "{\"execute\":\"input-send-event\",\"arguments\":{\"events\":[$1]}}" >/dev/null; }
	ev "{\"type\":\"abs\",\"data\":{\"axis\":\"x\",\"value\":$ax}},{\"type\":\"abs\",\"data\":{\"axis\":\"y\",\"value\":$ay}}"
	sleep 0.1
	ev '{"type":"btn","data":{"down":true,"button":"left"}}'
	sleep 0.1
	ev '{"type":"btn","data":{"down":false,"button":"left"}}'
	;;
shot)
	out=${2:?output path required}
	virsh screenshot "$DOMAIN" "$out.ppm" >/dev/null
	magick "$out.ppm" "$out" && rm -f "$out.ppm"
	;;
*) sed -n '2,8p' "$0" >&2; exit 1 ;;
esac
