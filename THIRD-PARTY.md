# Third-party components

Nothing in this repository is a third-party binary. The build script
downloads source code from upstream; the guest driver comes from your own
VMware Tools.

| Component | Used how | Licence |
|---|---|---|
| [qemus/qemu-vmvga](https://github.com/qemus/qemu-vmvga) v1.03 | cloned by `scripts/build.sh`; `patches/vmvga/` modify it (the patches contain context lines from it) | MIT file headers, GPL-2.0-or-later repository licence; our patches are GPL-2.0-or-later, both notices in [patches/vmvga/LICENSE.md](patches/vmvga/LICENSE.md) |
| [QEMU](https://www.qemu.org) 11.1.1 | downloaded by `scripts/build.sh`, signature verified, built locally | GPLv2 (parts GPLv2+, LGPL, BSD) |
| [DXVK](https://github.com/doitsujin/dxvk) v2.7.1 | cloned and built locally (DXVK-native) | zlib |
| VMware SVGA WDDM driver | **not included**; install it in the guest from your own copy of VMware Tools | VMware's licence |
| Microsoft Windows | **not included**; your own licensed copy | Microsoft's licence |

## Clean-room notes

- `guest/umd-shim/` is written from Microsoft's public Windows Driver Kit
  documentation of the D3D9 user-mode display driver interface (DDI); its
  header declares only the structures it needs. It contains no Microsoft or
  VMware code.
- `tools/d3d9-disasm.py` is written from the public description of the
  Direct3D 9 shader token format.
- VirtualBox's VMSVGA device (GPLv3) has been read as a reference for facts
  about the SVGA protocol only; no VirtualBox code is copied or translated
  into this repository.
- If you build and distribute QEMU binaries from this, the QEMU licence
  terms apply to those binaries.
