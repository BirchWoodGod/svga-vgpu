# Debugging guest rendering

Patch 0008 adds tooling to vmvga. Nothing changes unless the variables are
set; `scripts/vm.sh` passes them through to QEMU.

## Frame inspector

```sh
VMVGA_DUMP_DIR=$PWD/build/dump VM_DISK=... scripts/vm.sh start
touch build/dump/trigger          # while the game runs
tools/framedump2png.py build/dump # PNGs + min/max/mean per surface
```

- At the next present every render target's level 0 is written as
  `sid<N>_fmt<F>_<W>x<H>_pitch<P>.raw`; `framedump2png.py` decodes the
  usual colour, float and depth formats (and DXT/ATI via a DDS header).
- The frame after it is logged to `frame.txt`: every draw (shaders, colour
  and depth targets, bound textures, blend/depth/sRGB state, success or the
  failure stage), clear (with its acceleration result), copy and blit.
- `VMVGA_DUMP_PS=608,624`: in that frame, snapshot the first draw of each
  listed pixel shader into `draw_ps<id>/` and `draw_ps<id>.txt`: VS/PS
  bytecode, every constant, texture and render states, vertex declaration
  (as sent and as translated), vertex buffers, bound textures' CPU copies,
  and the colour targets read back right after the draw.
  `VMVGA_DUMP_ALL_RT=1` reads back every render target instead.
- `VMVGA_DUMP_TEXTURES=1`: also write CPU copies of large textures.
- `tools/d3d9-disasm.py ps608.bin` disassembles shader model 1–3 bytecode
  (and its constant table when present).

Typical use: dump the frame, find the first pass whose output is wrong,
snapshot the draws of that pass, read their shaders and inputs.

## Counters and logs

- `VMVGA_FPS=1`: every 5 s, presents/s (one StretchBlt per D3D9 Present:
  the frame rate), draws/s, FIFO and command-buffer traffic, GPU readbacks
  and the time spent in them.
- `VMVGA_LOG_VOLUME=1`: every volume-texture DMA and copy, with the reason
  when a DMA is rejected.
- `VMVGA-SHADER-BUDGET` and `VMVGA-BUDGET` lines: refused definitions.

## Profiler

`perf` is not needed:

```sh
VMVGA_PROFILE_DIR=$PWD/build/prof ... scripts/vm.sh start
touch build/prof/profile          # samples QEMU's main thread for 10 s
tools/profile-report.py build/prof
```

Samples the instruction pointer (and the top-of-stack word, which names the
caller of leaf routines like `memcpy`) every 0.5 ms of the main thread's CPU
time, then symbolizes with `llvm-symbolizer`.
