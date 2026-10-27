# Guest setup (Windows 7 x64)

Tested: Windows 7 SP1 x64 with the convenience rollup (KB3125574), the
SHA-2 update (KB4474419) and the January 2020 rollup.

## 1. Host

- `options kvm enable_vmware_backdoor=Y` (e.g. in
  `/etc/modprobe.d/kvm-vmware-backdoor.conf`), then reload the kvm modules.
  VMware's user-mode driver talks to the VMware backdoor I/O port from
  ring 3; without this KVM raises #GP and DWM crashes at login
  (`c0000096` in `vm3dum64.dll`). It only affects VMs with a vmport device.
- `scripts/build.sh`, then `VM_DISK=... scripts/vm.sh start` (the VM has
  `vmport` on).

## 2. VMware SVGA driver

Use **7.14.01.2032 from VMware Tools 9.4.10**. Driver 8.17.03.0005 (VMware
Tools 11.3.5) installs and runs Aero, but Halo Online crashes before its title
screen with it (not investigated yet).

The VMware Tools installer refuses to run on other hypervisors, so install
the driver by hand:

1. Extract `VmVideo.cab` from the VMware Tools package, then extract the cab.
   Some files inside carry `_debug`-style names where the INF expects
   `-debug`; rename them to match the INF.
2. `pnputil -i -a vm3d.inf` (as administrator). The INF matches
   `PCI\VEN_15AD&DEV_0405`, vmvga's device ID.
3. Reboot. Apply the "Windows 7" Aero theme if the taskbar stays opaque.

Disable guest sleep (`powercfg -change -standby-timeout-ac 0`, and the same
for `-monitor-timeout-ac` / `-hibernate-timeout-ac`): QEMU crashes when the
guest resumes from S3 with vmvga (not fixed yet).

## 3. D3D9 UMD shim

Needed for games that use the `NULL` render-target format or
block-compressed volume textures (Halo Online needs both).

```sh
cd guest/umd-shim
CFLAGS_EXTRA=-DSHIM_DIAG_FORMATS=1 OUT=out-diag ./build.sh   # the build Halo needs
```

`SHIM_DIAG_FORMATS=1` adds the volume-texture capability to DXT1–5/ATI1/ATI2
(and advertises a set of extra classic formats). Copy
`out-diag/w7xum9.dll` and `install.ps1` into the guest, then as
administrator:

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1   # -Uninstall restores the original
```

It copies the DLL to `SysWOW64`, points the adapter's
`UserModeDriverNameWow` at it and stores the real driver's name under
`HKLM\SOFTWARE\win7ext\umdshim\Target9`. **Reboot** afterwards: the UMD name
is read when the adapter starts. The shim logs to
`C:\ProgramData\win7ext\umdshim.log`. It is 32-bit only for now (games via
WOW64); the 64-bit UMD used by DWM is untouched.

## 4. Halo Online (the test game)

- Files copied from a CD keep the read-only attribute: `attrib -R /S /D`.
- Needs the DirectX End-User Runtime (June 2010) and the VC++ 2015–2019 x86
  runtime.
- `eldorado.exe -launcher -window -width 1024 -height 768`;
  `scripts/halo-test.sh` automates a run.
