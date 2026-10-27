# Performance

Halo Online (ElDewrito 0.6), Slayer on Guardian, 1024×768 windowed,
Windows 7 x64 guest with 4 vCPUs, host Ryzen 9 7950X + Radeon RX 7900
(RADV). Frame rate = presents per second (`VMVGA_FPS=1`).

| vmvga | Frames/s | Notes |
|---|---|---|
| 0001–0009 | 31–32 | ~830 draws/frame. QEMU main thread 64%, GPU 16%: nothing saturated. Not tied to QEMU's 30 ms display refresh (tested at 8 ms). Profile: 52% of the main thread in the CPU shadow clear. |
| + 0010 | 45–52 | Main thread 58%, game vCPU 54%, GPU 21%. |

## Where the time goes now

Main-thread profile with 0010 (share of its CPU time):

- copying guest memory into shadows (`vmsvga_gmr_transfer`): 10%
- GPU→CPU readbacks (`vmsvga3d_dxvk_surface_readback_level`): 9%. Two per
  frame, the back buffer and the window surface, ~0.85 ms each, during
  which the thread waits for the GPU.
- DXVK zero-filling newly created buffers (`D3D9Initializer::InitBuffer`):
  9%; buffers are re-created every frame
- the clears' fills: 9%
- buffer uploads: 6%

Since neither the CPU thread nor the GPU is saturated, the larger limit is
serialization: the guest waits for vmvga and vmvga waits for the guest
(about 7 command buffers per frame, each processed and completed in turn).

## Next

- Read back only the final window image, and overlap that readback with the
  next frame instead of waiting for it.
- Keep buffers instead of re-creating them.
- Let command-buffer processing overlap with the guest (more in flight).
