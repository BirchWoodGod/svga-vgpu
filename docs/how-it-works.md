# How it works

A vGPU has two halves: a driver in the guest that turns the game's
graphics calls into commands, and a device on the host that executes them on
the real GPU. Writing the guest half for Windows 7 x64 ourselves is not an
option for a daily system: new Windows 7 kernel drivers can no longer be
signed. So the guest half is a driver that **already has a valid signature**,
and all our work goes into the host half.

## Guest side

- **VMware SVGA 3D WDDM driver** (from VMware Tools). It drives VMware's
  virtual "SVGA II" card and speaks the SVGA3D command protocol, whose
  headers are public (MIT, in Mesa and the Linux `vmwgfx` driver).
  Version 7.14.01.2032 (VMware Tools 9.4.10) is the one that works here.
- **Our D3D9 UMD shim** (`guest/umd-shim/`, `w7xum9.dll`). The Direct3D 9
  runtime loads the display driver's user-mode part (UMD) by name from the
  registry. The shim is registered there instead, loads VMware's UMD and
  forwards everything, changing only the format list and resource creation:
  - FOURCC `NULL`, the vendor "dummy colour target" games use for depth-only
    passes, which VMware's driver doesn't have, is advertised and created as
    a small real format.
  - Block-compressed formats (DXT1–5, ATI1/2) also get the volume-texture
    capability, which Halo Online needs.
  User mode only; no Microsoft or VMware file is changed.

## Host side

- **QEMU 11.1.1** with **[qemus/qemu-vmvga](https://github.com/qemus/qemu-vmvga)**:
  an implementation of the SVGA II device with SVGA3D (FIFO, command
  buffers, GMRs, guest-backed objects, ~190 SVGA3D commands).
- vmvga translates the legacy (VGPU9) commands into **Direct3D 9 calls on
  DXVK-native** (`libdxvk_d3d9.so`) and the DX10/11 commands (VGPU10) into
  D3D11 on DXVK. There is no shader translator to write: the guest's D3D9
  shader bytecode goes straight to DXVK.
- DXVK runs it as **Vulkan** on the host GPU (RADV on AMD; any Vulkan
  driver should do).
- The finished frame is read back into the VM's framebuffer and shown
  through SPICE (or VNC).

## Memory

- Nothing is reserved on the GPU. DXVK allocates VRAM on demand like any
  Linux game, and the host desktop keeps working.
- The guest sees a reported video-memory size that follows `surface_mb`.
- vmvga keeps a CPU-side "shadow" copy of most surfaces (it is authoritative
  whenever the GPU copy is evicted), so host RAM use grows up to
  `surface_mb` (2048 MiB in `scripts/vm.sh`).

## One frame of Halo Online

Measured with the frame inspector (docs/debugging.md), Slayer on Guardian:
about 1,000 draws per frame.

1. G-buffer: albedo, normals and depth into three render targets at once.
2. Screen-space ambient occlusion (four full-screen passes), multiplied
   into the albedo.
3. Lighting: geometry drawn again with per-vertex spherical-harmonics
   light into an HDR buffer (stored scaled down).
4. Transparents, bloom, then tone mapping through a 16³ colour-grading LUT
   (a volume texture), HUD, composite.
5. Present: StretchBlt to the game's window, composed by the guest's DWM.

Every one of these stages hit at least one vmvga bug; see docs/fixes.md.
