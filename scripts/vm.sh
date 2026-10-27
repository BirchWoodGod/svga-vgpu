#!/usr/bin/env bash
# A Windows test VM with the vmvga 3D device, run under your own libvirt
# session (qemu:///session) with the QEMU built by scripts/build.sh.
# No network card. Nothing system-wide is touched.
#
#   VM_DISK=win7.qcow2 scripts/vm.sh start [vgpu]   # vgpu = 9, 10 or 11 (default 11)
#   scripts/vm.sh view                              # SPICE viewer
#   scripts/vm.sh destroy                           # power off
#
# Environment:
#   VM_DISK       guest disk (qcow2, SATA), required for start
#   VM_NAME       libvirt domain name (default: svga-vgpu)
#   VM_CDROM      optional ISO attached as a SATA CD-ROM
#   VM_XFER       optional raw disk image attached as a USB drive
#                 (handy for moving files in and out; read it with 7z)
#   VM_RAM_GIB    guest RAM (default 8)
#   BUILD_DIR     where scripts/build.sh put QEMU (default ./build)
#   VMVGA_SURFACE_MB  host-side surface budget (default 2048)
#   VMVGA_DEBUG   vmvga debug=on|off (default off)
#   DXVK_CONFIG, VMVGA_DUMP_*, VMVGA_LOG_VOLUME, VMVGA_FPS,
#   VMVGA_PROFILE_DIR  passed through to QEMU (see docs/debugging.md)
#
# Drive it with:  DOMAIN=$VM_NAME URI=qemu:///session scripts/vm-input.sh ...
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD_DIR=${BUILD_DIR:-$ROOT/build}
PREFIX=$BUILD_DIR/prefix
NAME=${VM_NAME:-svga-vgpu}
S="virsh -c qemu:///session"

define() {
	local vgpu=${1:-11} uuid cdrom="" xfer=""
	: "${VM_DISK:?set VM_DISK to the guest disk (qcow2)}"
	[[ -x $PREFIX/bin/qemu-system-x86_64 ]] || { echo "error: run scripts/build.sh first" >&2; exit 1; }
	# Keep the UUID when re-defining, or libvirt refuses the new XML.
	uuid=$($S domuuid "$NAME" 2>/dev/null || true)
	if [[ -n ${VM_CDROM:-} ]]; then
		cdrom="<disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='$(realpath "$VM_CDROM")'/><target dev='sdb' bus='sata'/><readonly/>
    </disk>"
	fi
	if [[ -n ${VM_XFER:-} ]]; then
		xfer="<disk type='file' device='disk'>
      <driver name='qemu' type='raw'/>
      <source file='$(realpath "$VM_XFER")'/><target dev='sdc' bus='usb'/>
    </disk>"
	fi
	mkdir -p "$BUILD_DIR"
	cat >"$BUILD_DIR/$NAME.xml" <<XML
<domain type='kvm' xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'>
  <name>$NAME</name>
  ${uuid:+<uuid>$uuid</uuid>}
  <memory unit='GiB'>${VM_RAM_GIB:-8}</memory>
  <vcpu>4</vcpu>
  <os><type arch='x86_64' machine='q35'>hvm</type><boot dev='hd'/></os>
  <features>
    <!-- The VMware guest driver talks to the VMware backdoor port;
         the host needs kvm.enable_vmware_backdoor=Y. -->
    <acpi/><apic/><vmport state='on'/>
    <hyperv mode='custom'>
      <relaxed state='on'/><vapic state='on'/><spinlocks state='on' retries='8191'/>
    </hyperv>
  </features>
  <cpu mode='host-passthrough' check='none'>
    <topology sockets='1' dies='1' clusters='1' cores='4' threads='1'/>
  </cpu>
  <clock offset='localtime'>
    <timer name='rtc' tickpolicy='catchup'/><timer name='hpet' present='no'/>
    <timer name='hypervclock' present='yes'/>
  </clock>
  <devices>
    <emulator>$PREFIX/bin/qemu-system-x86_64</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' discard='unmap'/>
      <source file='$(realpath "$VM_DISK")'/><target dev='sda' bus='sata'/>
    </disk>
    $cdrom
    $xfer
    <!-- USB 2.0/1.1 controllers: Windows 7 has no in-box xHCI driver, and
         libvirt's q35 default (qemu-xhci) leaves the tablet invisible. -->
    <controller type='usb' index='0' model='ich9-ehci1'/>
    <controller type='usb' index='0' model='ich9-uhci1'><master startport='0'/></controller>
    <controller type='usb' index='0' model='ich9-uhci2'><master startport='2'/></controller>
    <controller type='usb' index='0' model='ich9-uhci3'><master startport='4'/></controller>
    <input type='tablet' bus='usb'/>
    <!-- Games may refuse to start without an audio device. -->
    <sound model='ich9'/>
    <graphics type='spice' autoport='yes' listen='127.0.0.1'/>
    <video><model type='none'/></video>
    <memballoon model='none'/>
  </devices>
  <qemu:commandline>
    <qemu:arg value='-device'/>
    <qemu:arg value='vmvga,3d=on,vgpu=$vgpu,vgamem_mb=128,surface_mb=${VMVGA_SURFACE_MB:-2048},debug=${VMVGA_DEBUG:-off},bus=pcie.0,addr=0x10'/>
    <qemu:env name='LD_LIBRARY_PATH' value='$PREFIX/lib'/>
    <qemu:env name='DXVK_CONFIG' value='${DXVK_CONFIG:-}'/>
    <qemu:env name='VMVGA_DUMP_DIR' value='${VMVGA_DUMP_DIR:-$BUILD_DIR/framedump}'/>
    <qemu:env name='VMVGA_DUMP_TEXTURES' value='${VMVGA_DUMP_TEXTURES:-0}'/>
    <qemu:env name='VMVGA_DUMP_PS' value='${VMVGA_DUMP_PS:-}'/>
    <qemu:env name='VMVGA_DUMP_ALL_RT' value='${VMVGA_DUMP_ALL_RT:-0}'/>
    <qemu:env name='VMVGA_LOG_VOLUME' value='${VMVGA_LOG_VOLUME:-0}'/>
    <qemu:env name='VMVGA_FPS' value='${VMVGA_FPS:-0}'/>
    <qemu:env name='VMVGA_PROFILE_DIR' value='${VMVGA_PROFILE_DIR:-}'/>
  </qemu:commandline>
</domain>
XML
	$S define "$BUILD_DIR/$NAME.xml" >/dev/null
	echo "defined $NAME (vgpu=$vgpu)"
}

case ${1:?usage: vm.sh start|view|destroy} in
start)
	define "${2:-11}"
	$S start "$NAME"
	;;
view) spicy -h 127.0.0.1 -p "$($S domdisplay "$NAME" | sed -E 's/.*:([0-9]+).*/\1/')" & ;;
destroy) $S destroy "$NAME" ;;
*) sed -n '2,23p' "$0" >&2; exit 1 ;;
esac
