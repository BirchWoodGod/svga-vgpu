#!/usr/bin/env bash
# One Halo Online (ElDewrito 0.6) test cycle in the test VM (scripts/vm.sh):
# restart the VM (fresh QEMU/vmvga), log in, start the game windowed at
# 1024x768, wait for the title screen, press Enter, and capture screenshots.
# The screen checks assume a 1024x768 Windows 7 desktop with a password logon.
#
#   VM_DISK=win7.qcow2 VM_PASSWORD=... scripts/halo-test.sh [vgpu]   # vgpu = 11 (default) or 9
#
# Environment: everything scripts/vm.sh takes, plus
#   VM_PASSWORD   the guest account's password (required)
#   GAME_EXE      path of eldorado.exe in the guest (default C:\Games\HaloOnline\eldorado.exe)
#   MATCH=1       go on into a local Slayer match (main menu -> Host Multiplayer -> Start Game)
#   WATCH=n       screenshots to take afterwards, 4 s apart (default 20)
#   OUTDIR        where screenshots go (default $BUILD_DIR/halo-test)
# QEMU log: ~/.cache/libvirt/qemu/log/$VM_NAME.log
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD_DIR=${BUILD_DIR:-$ROOT/build}
OUTDIR=${OUTDIR:-$BUILD_DIR/halo-test}
VGPU=${1:-11}
export VM_NAME=${VM_NAME:-svga-vgpu}
export DOMAIN=$VM_NAME URI=qemu:///session
: "${VM_PASSWORD:?set VM_PASSWORD to the guest account password}"
GAME_EXE=${GAME_EXE:-'C:\Games\HaloOnline\eldorado.exe'}
T="$ROOT/scripts/vm-input.sh"
V() { virsh -c qemu:///session "$@"; }
mkdir -p "$OUTDIR"
rm -f "$OUTDIR"/*.png

mean() { magick "$1" ${2:+-crop "$2"} -format '%[fx:mean]' info:; }

# 1. Fresh VM.
if [[ $(V domstate "$VM_NAME" 2>/dev/null) == running ]]; then
	V destroy "$VM_NAME" >/dev/null
fi
"$ROOT/scripts/vm.sh" start "$VGPU" >/dev/null

# 2. Login screen (resolution switches to 1024x768 once the VMware driver runs).
for i in $(seq 1 60); do
	sleep 3
	"$T" shot "$OUTDIR/boot.png" 2>/dev/null || continue
	[[ $(magick identify -format '%w' "$OUTDIR/boot.png") == 1024 ]] || continue
	# The password box is white in the middle of the screen.
	awk -v m="$(mean "$OUTDIR/boot.png" 220x20+400+497)" 'BEGIN{exit !(m > 0.9)}' && break
done
"$T" text "$VM_PASSWORD"
"$T" key KEY_ENTER
sleep 35

# 3. Start the game.
"$T" chord KEY_LEFTMETA KEY_R
sleep 2
"$T" text "$GAME_EXE -launcher -window -width 1024 -height 768"
"$T" key KEY_ENTER

# 4. Title screen: the "Press Enter To Continue" line is bright on a dark background.
title=0
for i in $(seq 1 60); do
	sleep 4
	"$T" shot "$OUTDIR/title.png"
	if awk -v m="$(mean "$OUTDIR/title.png" 200x30+410+572)" -v t="$(mean "$OUTDIR/title.png" 1024x60+0+700)" \
		'BEGIN{exit !(m > 0.25 && t < 0.4)}'; then
		title=1
		break
	fi
done
echo "title screen: $title (after $((i * 4))s)"
sleep 5

# 5. Enter, then watch.
"$T" click 900 500
sleep 1
"$T" key KEY_ENTER

# Optional: MATCH=1 goes on into a local Slayer match
# (main menu -> Host Multiplayer -> Start Game).
if [[ ${MATCH:-0} == 1 ]]; then
	sleep 20
	"$T" shot "$OUTDIR/menu.png"
	"$T" key KEY_DOWN
	sleep 1
	"$T" key KEY_ENTER
	sleep 10
	"$T" shot "$OUTDIR/lobby.png"
	"$T" key KEY_ENTER
	sleep 30
fi
for n in $(seq 1 ${WATCH:-20}); do
	sleep 4
	"$T" shot "$OUTDIR/after-$n.png"
	printf 'after-%s mean=%s\n' "$n" "$(mean "$OUTDIR/after-$n.png")"
done
