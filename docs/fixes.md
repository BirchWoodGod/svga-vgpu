# Fixes to qemu-vmvga

Each patch in `patches/vmvga/` starts with a description; this is the
overview, in the order they were found while bringing up Halo Online on
Windows 7 x64 with VMware's 7.14 driver. Patches apply in order to
qemu-vmvga v1.03.

| Patch | Symptom | Cause |
|---|---|---|
| 0001 | ATI1/ATI2 textures mishandled | not treated as block-compressed (speculative render-target creation, texture hints) |
| 0002 | every draw using an ATI2 normal map dropped | D3D9 reports the ATI1/ATI2 lock pitch per pixel row; vmvga expected block rows and rejected every upload |
| 0003 | black main menu | the fixed 512 MiB surface budget ran out while loading; later surfaces refused silently, draws using them dropped. Now a `surface_mb` property |
| 0004 | all instanced level geometry missing | instance buffer declared first became D3D9 stream 0, which may not hold instance data; DXVK rejected it |
| 0005 | DXT5 volume textures empty | guest slice pitch counted pixel rows instead of block rows, so slices were looked for 4x too far and the upload failed validation |
| 0006 | **black 3D world** in a match | the active colour-grading LUT (a 16³ volume texture already on the GPU) never got its data: before a DMA, vmvga reads the GPU copy back, which fails for volume textures. A write covering the whole image now skips the readback |
| 0007 | image crushed, far too dark | `SVGA3D_RS_OUTPUTGAMMA` (the guest's `D3DRS_SRGBWRITEENABLE`) was ignored |
| 0008 | — | debug tooling (frame inspector, counters, profiler), off unless enabled; see docs/debugging.md |
| 0009 | first-person weapon and 33 other draws per frame missing | the 8 MiB per-shader limit was also used as the limit for all shaders together; Halo passes 8 MiB, later shader definitions refused silently |
| 0010 | 31–32 fps | an accelerated clear also clears the CPU shadow, byte by byte: 52% of the main thread. Now row fills at memory speed: 45–52 fps |

How 0005–0007 were found, as an example of the method: dump every render
target of a frame → G-buffer correct → snapshot after each later pass →
lighting correct → tone-mapping output zero → disassemble its pixel shader
→ its output is a lookup in a volume texture → that texture's CPU copy is
empty → log volume uploads → the upload was rejected, and why.

## Known open issues

- Guest S3 resume crashes QEMU (disable guest sleep).
- VMware driver 8.17: Halo Online crashes before its title screen.
- A DWM composition glitch: a dialog showed a magnified icon instead of its
  contents.
