#!/usr/bin/env bash
# Build QEMU 11.1.1 with the qemus/qemu-vmvga SVGA3D device (plus our
# patches from patches/vmvga/) and DXVK-native into a user-local prefix.
# Nothing is installed system-wide.
#
#   scripts/build.sh                 # into ./build
#   BUILD_DIR=/some/dir scripts/build.sh
#
# Result:
#   $BUILD_DIR/prefix/bin/qemu-system-x86_64   QEMU + patched vmvga
#   $BUILD_DIR/prefix/lib/libdxvk_d3d9.so.0    DXVK-native (dlopen'ed by vmvga)
#   $BUILD_DIR/env.sh                          LD_LIBRARY_PATH for running it
set -euo pipefail

QEMU_VER=11.1.1
VMVGA_TAG=v1.03       # targets QEMU 11.1.1
DXVK_TAG=v2.7.1       # the version vmvga's code is written against
JOBS=${JOBS:-8}        # host RAM is tight; raise when nothing else runs
# QEMU release signing key (Michael Roth), as published on qemu.org/download
QEMU_KEY=CEACC9E15534EBABB82D3FA03353C9CEF108B584

ROOT=$(cd "$(dirname "$0")/.." && pwd)
B=${BUILD_DIR:-$ROOT/build}
SRC=$B/src
PREFIX=$B/prefix
mkdir -p "$SRC" "$PREFIX"
cd "$SRC"

echo "== sources"
[[ -f qemu-$QEMU_VER.tar.xz ]] || curl -fLO "https://download.qemu.org/qemu-$QEMU_VER.tar.xz"
[[ -f qemu-$QEMU_VER.tar.xz.sig ]] || curl -fLO "https://download.qemu.org/qemu-$QEMU_VER.tar.xz.sig"
[[ -d vmvga ]] || git clone -q --depth 1 --branch "$VMVGA_TAG" https://github.com/qemus/qemu-vmvga.git vmvga
[[ -d dxvk ]] || git clone -q --depth 1 --branch "$DXVK_TAG" --recurse-submodules --shallow-submodules \
	https://github.com/doitsujin/dxvk.git dxvk

echo "== verify qemu tarball signature"
# Separate keyring so the user's own GnuPG setup is untouched.
export GNUPGHOME=$B/gnupg
mkdir -p "$GNUPGHOME" && chmod 700 "$GNUPGHOME"
gpg -q --keyserver hkps://keyserver.ubuntu.com --recv-keys "$QEMU_KEY" 2>/dev/null || true
gpg --status-fd 1 --verify "qemu-$QEMU_VER.tar.xz.sig" "qemu-$QEMU_VER.tar.xz" 2>/dev/null |
	grep -q "VALIDSIG $QEMU_KEY" || { echo "error: bad or missing signature on qemu-$QEMU_VER.tar.xz" >&2; exit 1; }
echo "   signed by $QEMU_KEY"

# Run a build step quietly, logging to $B/logs/<name>.log; show the
# log's tail if it fails.
mkdir -p "$B/logs"
step() {
	local name=$1
	shift
	"$@" >"$B/logs/$name.log" 2>&1 || {
		echo "error: $name failed, see $B/logs/$name.log" >&2
		tail -n 30 "$B/logs/$name.log" >&2
		exit 1
	}
}

echo "== dxvk-native $DXVK_TAG"
if [[ ! -f $PREFIX/lib/libdxvk_d3d9.so.0 ]]; then
	step dxvk-setup meson setup --reconfigure dxvk/build.native dxvk \
		--buildtype release --prefix "$PREFIX" --libdir lib -Dnative_sdl2=enabled
	step dxvk-build ninja -j"$JOBS" -C dxvk/build.native install
fi

echo "== qemu $QEMU_VER + vmvga $VMVGA_TAG"
if [[ ! -d qemu-$QEMU_VER ]]; then
	tar xf "qemu-$QEMU_VER.tar.xz"
	# Our fixes to vmvga (patches/vmvga), applied in order before the overlay copy.
	for p in "$ROOT"/patches/vmvga/*.patch; do
		[[ -e $p ]] || continue
		git -C vmvga apply --check "$p" 2>/dev/null && git -C vmvga apply "$p" && echo "   applied ${p##*/}"
	done
	cp -r vmvga/hw/. "qemu-$QEMU_VER/hw/"
fi
if [[ ! -x $PREFIX/bin/qemu-system-x86_64 ]]; then
	cd "qemu-$QEMU_VER"
	# No SDL: vmvga supplies its own SDL2 ABI for DXVK's headless WSI and
	# fails if QEMU has already loaded the real libSDL2.
	step qemu-configure ./configure --prefix="$PREFIX" --target-list=x86_64-softmmu \
		--enable-kvm --enable-spice --enable-vnc --disable-sdl --disable-docs --disable-werror
	step qemu-build make -j"$JOBS"
	step qemu-install make install
	cd "$SRC"
fi

cat >"$B/env.sh" <<EOF
export LD_LIBRARY_PATH=$PREFIX/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}
EOF

"$PREFIX/bin/qemu-system-x86_64" --version | head -1
LD_LIBRARY_PATH=$PREFIX/lib "$PREFIX/bin/qemu-system-x86_64" -device vmvga,help | head -20
