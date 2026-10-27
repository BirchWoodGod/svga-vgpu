#!/usr/bin/env python3
"""Disassemble Direct3D 9 shader bytecode (vs/ps 1.x-3.0) dumped by vmvga.

    tools/d3d9-disasm.py build/framedump-HHMMSS/ps608.bin

Written from the public token format description (D3D9 shader model
"Shader Code Format"): version token, instruction tokens with the length in
bits 24-27, destination/source parameter tokens, DCL/DEF special cases and
comment blocks. A CTAB comment (D3DX constant table) is decoded into
constant names when present.
"""
import struct
import sys

OPS = {
    0: "nop", 1: "mov", 2: "add", 3: "sub", 4: "mad", 5: "mul", 6: "rcp", 7: "rsq",
    8: "dp3", 9: "dp4", 10: "min", 11: "max", 12: "slt", 13: "sge", 14: "exp",
    15: "log", 16: "lit", 17: "dst", 18: "lrp", 19: "frc", 20: "m4x4", 21: "m4x3",
    22: "m3x4", 23: "m3x3", 24: "m3x2", 25: "call", 26: "callnz", 27: "loop",
    28: "ret", 29: "endloop", 30: "label", 31: "dcl", 32: "pow", 33: "crs",
    34: "sgn", 35: "abs", 36: "nrm", 37: "sincos", 38: "rep", 39: "endrep",
    40: "if", 41: "ifc", 42: "else", 43: "endif", 44: "break", 45: "breakc",
    46: "mova", 47: "defb", 48: "defi", 64: "texcoord", 65: "texkill", 66: "tex",
    67: "texbem", 68: "texbeml", 69: "texreg2ar", 70: "texreg2gb",
    71: "texm3x2pad", 72: "texm3x2tex", 73: "texm3x3pad", 74: "texm3x3tex",
    76: "texm3x3spec", 77: "texm3x3vspec", 78: "expp", 79: "logp", 80: "cnd",
    81: "def", 82: "texreg2rgb", 83: "texdp3tex", 84: "texm3x2depth",
    85: "texdp3", 86: "texm3x3", 87: "texdepth", 88: "cmp", 89: "bem",
    90: "dp2add", 91: "dsx", 92: "dsy", 93: "texldd", 94: "setp", 95: "texldl",
    96: "breakp",
}
NO_DEST = {25, 26, 27, 28, 29, 30, 38, 39, 40, 41, 42, 43, 44, 45, 96}
REG = {
    0: "r", 1: "v", 2: "c", 3: "a", 4: "oPos", 5: "oD", 6: "o", 7: "i", 8: "oC",
    9: "oDepth", 10: "s", 11: "c", 12: "c", 13: "c", 14: "b", 15: "aL",
    16: "half", 17: "misc", 18: "l", 19: "p",
}
USAGE = ["position", "blendweight", "blendindices", "normal", "psize", "texcoord",
         "tangent", "binormal", "tessfactor", "positiont", "color", "fog", "depth",
         "sample"]
SAMPLER = {1: "1d", 2: "2d", 3: "cube", 4: "volume"}
CMP = {1: "_gt", 2: "_eq", 3: "_ge", 4: "_lt", 5: "_ne", 6: "_le"}
SRCMOD = {1: "-{}", 2: "{}_bias", 3: "-{}_bias", 4: "{}_bx2", 5: "-{}_bx2",
          6: "1-{}", 7: "{}_x2", 8: "-{}_x2", 9: "{}_dz", 10: "{}_dw",
          11: "{}_abs", 12: "-{}_abs", 13: "!{}"}


def regname(tok, ps, major):
    rtype = ((tok >> 28) & 7) | ((tok >> 8) & 0x18)
    num = tok & 0x7FF
    if rtype == 3:
        return f"t{num}" if ps else f"a{num}"
    if rtype == 6 and major < 3 and not ps:
        return f"oT{num}"
    if rtype == 17:
        return "vPos" if num == 0 else "vFace"
    if rtype in (4, 9, 15):
        return REG[rtype] if rtype != 4 else ["oPos", "oFog", "oPts"][num]
    return f"{REG.get(rtype, f'?{rtype}_')}{num}"


def dest(tok, ps, major, rel=""):
    mask = (tok >> 16) & 0xF
    mod = (tok >> 20) & 0xF
    name = regname(tok, ps, major) + rel
    if mask != 0xF:
        name += "." + "".join(c for i, c in enumerate("xyzw") if mask & (1 << i))
    mods = ("_sat" if mod & 1 else "") + ("_pp" if mod & 2 else "") + ("_centroid" if mod & 4 else "")
    return mods, name


def source(tok, ps, major, rel=""):
    sw = (tok >> 16) & 0xFF
    mod = (tok >> 24) & 0xF
    comps = "".join("xyzw"[(sw >> (2 * i)) & 3] for i in range(4))
    name = regname(tok, ps, major) + rel
    if comps != "xyzw":
        if len(set(comps)) == 1:
            comps = comps[0]
        name += "." + comps
    return SRCMOD[mod].format(name) if mod in SRCMOD else name


def ctab(words):
    data = struct.pack(f"<{len(words)}I", *words)
    if data[:4] != b"CTAB":
        return None
    d = data[4:]

    def cstr(off):
        return d[off:d.index(b"\0", off)].decode("latin-1")

    _, creator, _, count, info, _, target = struct.unpack_from("<7I", d, 0)
    out = [f"// CTAB creator '{cstr(creator)}' target '{cstr(target)}'"]
    sets = ["b", "i", "c", "s"]
    for n in range(count):
        name, rset, rindex, rcount, _, _, _ = struct.unpack_from("<IHHHHII", d, info + 20 * n)
        out.append(f"//   {sets[rset] if rset < 4 else '?'}{rindex:<4d} x{rcount:<3d} {cstr(name)}")
    return out


def disasm(words):
    ver = words[0]
    ps = (ver >> 16) == 0xFFFF
    major, minor = (ver >> 8) & 0xFF, ver & 0xFF
    lines = [f"{'ps' if ps else 'vs'}_{major}_{minor}"]
    i, depth = 1, 1
    while i < len(words):
        tok = words[i]
        op = tok & 0xFFFF
        if op == 0xFFFF:
            break
        if op == 0xFFFE:
            n = (tok >> 16) & 0x7FFF
            t = ctab(words[i + 1:i + 1 + n])
            if t:
                lines += t
            i += 1 + n
            continue
        length = (tok >> 24) & 0xF if major >= 2 else None
        ctrl = (tok >> 16) & 0xFF
        params = words[i + 1:i + 1 + length] if length is not None else []
        i += 1 + (length or 0)
        if op in (29, 39, 42, 43):
            depth -= 1
        pad = "  " * depth
        name = OPS.get(op, f"op{op}")
        if op == 31:  # dcl
            info, reg = params[0], params[1]
            _, rn = dest(reg, ps, major)
            if ((reg >> 28) & 7 | (reg >> 8) & 0x18) == 10:
                lines.append(f"{pad}dcl_{SAMPLER.get((info >> 27) & 0xF, '?')} {rn}")
            else:
                u = info & 0x1F
                idx = (info >> 16) & 0xF
                uname = USAGE[u] if u < len(USAGE) else f"usage{u}"
                lines.append(f"{pad}dcl_{uname}{idx if idx else ''} {rn}")
            continue
        if op in (81, 48):  # def, defi
            fmt = "f" if op == 81 else "i"
            vals = struct.unpack(f"<4{fmt}", struct.pack("<4I", *params[1:5]))
            lines.append(f"{pad}{name} {dest(params[0], ps, major)[1]}, " + ", ".join(f"{v:g}" for v in vals))
            continue
        if op == 47:  # defb
            lines.append(f"{pad}defb {dest(params[0], ps, major)[1]}, {bool(params[1])}")
            continue
        if op == 66 and ctrl:
            name = {1: "texldp", 2: "texldb"}.get(ctrl, name)
        elif op == 66 and major >= 2:
            name = "texld"
        elif op in (41, 45, 94):
            name += CMP.get(ctrl, "")
        pred = ""
        if tok & (1 << 28):
            # Predicated: the predicate source is the last parameter.
            pred = "(" + source(params[-1], ps, major) + ") "
            params = params[:-1]
        operands, mods, j = [], "", 0
        while j < len(params):
            p = params[j]
            rel = ""
            if p & (1 << 13) and major >= 2 and j + 1 < len(params):
                rel = "[" + source(params[j + 1], ps, major) + "]"
                j += 1
            if j == 0 or (rel and len(operands) == 0 and op not in NO_DEST):
                pass
            if not operands and op not in NO_DEST:
                mods, d = dest(p, ps, major, rel)
                operands.append(d)
            else:
                operands.append(source(p, ps, major, rel))
            j += 1
        lines.append(f"{pad}{pred}{name}{mods} " + ", ".join(operands))
        if op in (27, 38, 40, 41, 42):
            depth += 1
    return lines


def main():
    for path in sys.argv[1:]:
        raw = open(path, "rb").read()
        words = list(struct.unpack(f"<{len(raw) // 4}I", raw[: len(raw) // 4 * 4]))
        print(f"// {path}")
        print("\n".join(disasm(words)))


if __name__ == "__main__":
    main()
