#!/usr/bin/env bash
# Build w7xum9.dll (32-bit) with the host's clang + lld; no Windows SDK or
# MinGW needed. Import libraries are generated from the .def files below.
set -euo pipefail

cd "$(dirname "$0")"
OUT=${OUT:-out}
mkdir -p "$OUT"

# Decorated stdcall names; --kill-at imports them by their plain names.
cat >"$OUT/kernel32.def" <<'EOF'
LIBRARY kernel32.dll
EXPORTS
LoadLibraryW@4
GetProcAddress@8
GetSystemDirectoryW@8
CreateFileW@28
WriteFile@20
CloseHandle@4
CreateDirectoryW@8
GetCurrentProcessId@0
GetModuleFileNameW@12
GlobalMemoryStatusEx@4
EOF
cat >"$OUT/advapi32.def" <<'EOF'
LIBRARY advapi32.dll
EXPORTS
RegOpenKeyExW@20
RegQueryValueExW@24
RegCloseKey@4
EOF
for lib in kernel32 advapi32; do
	llvm-dlltool -m i386 -k -d "$OUT/$lib.def" -l "$OUT/$lib.lib"
done

clang --target=i686-pc-windows-msvc ${CFLAGS_EXTRA:-} -O2 -std=c11 -Wall -Wextra -Wno-unused-parameter \
	-ffreestanding -fno-builtin -nostdlib -mno-stack-arg-probe \
	-fuse-ld=lld -shared \
	-Wl,/entry:DllMain@12 -Wl,/export:OpenAdapter=_OpenAdapter@4 \
	-Xlinker /subsystem:windows,6.0 -Wl,/nodefaultlib \
	-o "$OUT/w7xum9.dll" umdshim.c "$OUT/kernel32.lib" "$OUT/advapi32.lib"

llvm-readobj --coff-exports "$OUT/w7xum9.dll" | grep -E 'Name:'
llvm-readobj --coff-imports "$OUT/w7xum9.dll" | grep -E 'Name:|Symbol:' | tr -s ' ' | paste -sd' '
ls -la "$OUT/w7xum9.dll"
