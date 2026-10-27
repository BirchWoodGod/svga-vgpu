#!/usr/bin/env python3
"""Flat profile from vmvga's sampling profiler (VMVGA_PROFILE_DIR).

    tools/profile-report.py build/profile-HHMMSS [top]

Reads samples.txt (instruction pointer and top-of-stack word per sample)
and maps (/proc/self/maps of the QEMU process), resolves addresses to
module + offset, symbolizes with llvm-symbolizer and prints the hottest
modules and functions, plus the callers of samples that landed in libc
(memcpy and friends are leaf routines, so the top-of-stack word is their
return address).
"""
import bisect
import collections
import subprocess
import sys
from pathlib import Path


def load_maps(path):
    maps = []
    for line in Path(path).read_text().splitlines():
        parts = line.split(None, 5)
        if len(parts) < 6 or "x" not in parts[1]:
            continue
        start, end = (int(x, 16) for x in parts[0].split("-"))
        maps.append((start, end, int(parts[2], 16), parts[5]))
    return maps


def locate(maps, addr):
    for start, end, off, name in maps:
        if start <= addr < end:
            return name, addr - start + off
    return None, None


def load_dynsyms(module):
    out = subprocess.run(["nm", "-D", "--defined-only", module],
                         capture_output=True, text=True).stdout
    syms = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[1] in "TtWi":
            syms.append((int(parts[0], 16), parts[2]))
    syms.sort()
    return syms


class Symbolizer:
    def __init__(self):
        self.cache = {}
        self.dynsyms = {}

    def names(self, module, offsets):
        """Map each offset in module to a function name."""
        todo = [o for o in set(offsets) if (module, o) not in self.cache]
        if todo and Path(module).exists():
            query = "\n".join(hex(o) for o in todo) + "\n"
            out = subprocess.run(
                ["llvm-symbolizer", "--obj", module, "--functions=linkage",
                 "--no-inlines", "--demangle"],
                input=query, capture_output=True, text=True).stdout
            for o, blk in zip(todo, out.strip().split("\n\n")):
                name = blk.split("\n")[0]
                if name == "??":
                    if module not in self.dynsyms:
                        self.dynsyms[module] = load_dynsyms(module)
                    syms = self.dynsyms[module]
                    i = bisect.bisect_right(syms, (o, "￿")) - 1
                    name = f"{syms[i][1]}~" if i >= 0 else "??"
                self.cache[(module, o)] = f"{name}  [{Path(module).name}]"
        for o in todo:
            self.cache.setdefault((module, o), f"??  [{Path(module).name}]")
        return [self.cache[(module, o)] for o in offsets]


def main():
    folder = Path(sys.argv[1])
    top = int(sys.argv[2]) if len(sys.argv) > 2 else 40
    maps = load_maps(folder / "maps")
    rows = [line.split() for line in (folder / "samples.txt").read_text().splitlines() if line]
    samples = [(int(r[0], 16), int(r[1], 16) if len(r) > 1 else 0) for r in rows]
    sym = Symbolizer()

    by_module = collections.Counter()
    per_module = collections.defaultdict(list)
    libc_callers = collections.defaultdict(list)
    for ip, top_word in samples:
        module, off = locate(maps, ip)
        by_module[module or "?"] += 1
        if module is None:
            continue
        per_module[module].append(off)
        if Path(module).name.startswith("libc.so"):
            cmod, coff = locate(maps, top_word)
            if cmod is not None:
                libc_callers[cmod].append(coff)

    funcs = collections.Counter()
    for module, offsets in per_module.items():
        funcs.update(sym.names(module, offsets))
    callers = collections.Counter()
    for module, offsets in libc_callers.items():
        callers.update(sym.names(module, offsets))

    total = len(samples)
    print(f"{total} samples ({total * 0.5 / 1000:.1f} s of main-thread CPU)\n")
    print("modules:")
    for name, n in by_module.most_common(12):
        print(f"  {100 * n / total:5.1f}%  {Path(name).name}")
    print("\nfunctions:")
    for name, n in funcs.most_common(top):
        print(f"  {100 * n / total:5.1f}%  {name}")
    if callers:
        print("\ncallers of libc samples (top-of-stack return address):")
        for name, n in callers.most_common(15):
            print(f"  {100 * n / total:5.1f}%  {name}")


if __name__ == "__main__":
    main()
