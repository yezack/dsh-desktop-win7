#!/usr/bin/env python3
"""PE diagnostics for Windows 7 compatibility.

Three independent checks, all stdlib-only:

  version <file>...        Print the optional-header OS/subsystem version fields
                           that Windows' loader enforces. An image declaring a
                           OS version newer than the running OS is refused with
                           STATUS_INVALID_IMAGE_FORMAT (0xC000007B,
                           "not a valid Win32 application") before any code runs.

  imports <file>...        Diff every statically imported symbol against the
                           exports actually present in this machine's system
                           DLLs, and report the ones that are missing. On
                           Windows 7 this is exactly the set VxKex NEXT has to
                           supply.

  scan <dir> [maj] [min]   Walk a directory and list .exe/.dll/.node images
                           declaring an OS version above maj.min (default 6.1).

Exit codes: 0 = clean, 1 = findings, 2 = usage error.
"""
from __future__ import annotations

import os
import struct
import sys

TARGET_EXTS = ('.exe', '.dll', '.node')
SKIP_DLL_PREFIXES = ('api-ms-win-', 'ext-ms-win-')

# Offsets inside the COFF optional header (identical for PE32 and PE32+).
OPT_OS_MAJOR = 40
OPT_OS_MINOR = 42
OPT_SUB_MAJOR = 48
OPT_SUB_MINOR = 50
OPT_SUBSYSTEM = 68
OPT_DLLCHARACTERISTICS = 70


def _cstr(data: bytes, off):
    if off is None or off < 0 or off >= len(data):
        return '<bad-offset>'
    end = data.find(b'\0', off)
    if end < 0:
        end = len(data)
    return data[off:end].decode('latin1', 'replace')


class PE:
    """Just enough PE parsing to read imports, exports and header versions."""

    def __init__(self, path: str):
        with open(path, 'rb') as handle:
            self.data = handle.read()
        data = self.data
        if len(data) < 0x40 or data[:2] != b'MZ':
            raise ValueError('not a PE file (no MZ)')
        pe_off = struct.unpack_from('<I', data, 0x3C)[0]
        if pe_off + 0x40 > len(data) or data[pe_off:pe_off + 4] != b'PE\0\0':
            raise ValueError('not a PE file (no PE signature)')
        coff = pe_off + 4
        self.machine = struct.unpack_from('<H', data, coff)[0]
        self.characteristics = struct.unpack_from('<H', data, coff + 18)[0]
        nsec = struct.unpack_from('<H', data, coff + 2)[0]
        size_opt = struct.unpack_from('<H', data, coff + 16)[0]
        opt = coff + 20
        self.optional_offset = opt
        self.magic = struct.unpack_from('<H', data, opt)[0]
        self.pe32plus = self.magic == 0x20B
        dd_off = opt + (112 if self.pe32plus else 96)
        self.dirs = [struct.unpack_from('<II', data, dd_off + i * 8) for i in range(16)]
        sec_off = opt + size_opt
        self.sections = []
        for i in range(nsec):
            o = sec_off + i * 40
            vsize, vaddr, rawsize, rawptr = struct.unpack_from('<IIII', data, o + 8)
            self.sections.append((vaddr, vsize, rawptr, rawsize))

    # -- section helpers ---------------------------------------------------
    def rva2off(self, rva):
        for vaddr, vsize, rawptr, rawsize in self.sections:
            if vaddr <= rva < vaddr + max(vsize, rawsize):
                off = rawptr + (rva - vaddr)
                return off if off < len(self.data) else None
        return None

    def versions(self) -> dict:
        data, opt = self.data, self.optional_offset
        os_major, os_minor, img_major, img_minor, sub_major, sub_minor = struct.unpack_from(
            '<HHHHHH', data, opt + OPT_OS_MAJOR)
        return {
            'os': (os_major, os_minor),
            'image': (img_major, img_minor),
            'subsystem': (sub_major, sub_minor),
            'subsystem_kind': struct.unpack_from('<H', data, opt + OPT_SUBSYSTEM)[0],
            'machine': self.machine,
            'pe32plus': self.pe32plus,
            'size': len(data),
        }

    # -- imports -----------------------------------------------------------
    def imports(self, which=1):
        """which: 1 = import table, 13 = delay-import table."""
        out = []
        rva, _size = self.dirs[which]
        if not rva:
            return out
        off = self.rva2off(rva)
        if off is None:
            return out
        i = 0
        while i < 8192:
            o = off + i * 20
            if o + 20 > len(self.data):
                break
            oft, _tds, _fc, name_rva, ft = struct.unpack_from('<IIIII', self.data, o)
            if oft == 0 and name_rva == 0 and ft == 0:
                break
            dll = _cstr(self.data, self.rva2off(name_rva))
            thunk = self.rva2off(oft or ft)
            syms = []
            if thunk is not None:
                step = 8 if self.pe32plus else 4
                high = 1 << (63 if self.pe32plus else 31)
                j = 0
                while j < 65536:
                    p = thunk + j * step
                    if p + step > len(self.data):
                        break
                    value = struct.unpack_from('<Q' if self.pe32plus else '<I', self.data, p)[0]
                    if value == 0:
                        break
                    if value & high:
                        syms.append(('ord', value & 0xFFFF))
                    else:
                        name_off = self.rva2off(value)
                        syms.append(('name', _cstr(self.data, name_off + 2 if name_off is not None else None)))
                    j += 1
            out.append((dll, syms))
            i += 1
        return out

    # -- exports -----------------------------------------------------------
    def exports(self):
        names, ordinals = set(), set()
        rva, _size = self.dirs[0]
        if not rva:
            return names, ordinals
        o = self.rva2off(rva)
        if o is None:
            return names, ordinals
        fields = struct.unpack_from('<IIHHIIIIIII', self.data, o)
        base, nfunc, nnames = fields[5], fields[6], fields[7]
        addr_names, addr_ords = fields[9], fields[10]
        ao, oo = self.rva2off(addr_names), self.rva2off(addr_ords)
        if ao is not None:
            for i in range(min(nnames, 400000)):
                nrva = struct.unpack_from('<I', self.data, ao + i * 4)[0]
                names.add(_cstr(self.data, self.rva2off(nrva)))
        if oo is not None:
            for i in range(min(nfunc, 400000)):
                ordinals.add(base + i)
        return names, ordinals


def system32_dir() -> str:
    return os.path.join(os.environ.get('SystemRoot', r'C:\Windows'), 'System32')


def cmd_version(paths):
    findings = 0
    for path in paths:
        try:
            info = PE(path).versions()
        except Exception as exc:  # noqa: BLE001 - report, do not crash the sweep
            print('=== %s\n    ERROR: %s' % (path, exc))
            continue
        machine = {0x8664: 'x64', 0x14C: 'x86', 0xAA64: 'arm64'}.get(info['machine'], hex(info['machine']))
        osv, sub, img = info['os'], info['subsystem'], info['image']
        print('=== %s' % path)
        print('    size            : %.1f MB' % (info['size'] / 1048576.0))
        print('    machine         : %s' % machine)
        print('    image version   : %d.%d' % img)
        print('    OS version      : %d.%d' % osv)
        print('    subsystem ver   : %d.%d' % sub)
        if osv > (6, 1) or sub > (6, 1):
            print('    >>> LOADER CHECK: declares newer than Windows 7 (6.1)')
            findings += 1
        else:
            print('    loader check    : OK for Windows 7 (6.1)')
    return 1 if findings else 0


def cmd_imports(paths):
    system32 = system32_dir()
    findings = 0
    for path in paths:
        print('=== %s' % path)
        try:
            top = PE(path)
        except Exception as exc:  # noqa: BLE001
            print('    ERROR: %s' % exc)
            continue
        missing = []
        for which in (1, 13):
            for dll, syms in top.imports(which):
                low = dll.lower()
                if low.startswith(SKIP_DLL_PREFIXES):
                    continue
                target = os.path.join(system32, dll)
                if not os.path.isfile(target):
                    continue
                try:
                    have_names, have_ords = PE(target).exports()
                except Exception:  # noqa: BLE001
                    continue
                for kind, value in syms:
                    if kind == 'name':
                        if value not in have_names:
                            missing.append((dll, value))
                    elif value not in have_ords:
                        missing.append((dll, '#%d' % value))
        if missing:
            print('    MISSING SYMBOLS (%d) — these must be supplied by a compatibility layer:' % len(missing))
            for dll, value in missing:
                print('      %-24s %s' % (dll, value))
            findings += 1
        else:
            print('    all imported symbols resolve against this system')
    return 1 if findings else 0


def cmd_scan(root, min_major=6, min_minor=1):
    files = []
    if os.path.isfile(root):
        files = [root]
    else:
        for base, _dirs, names in os.walk(root):
            for name in names:
                if name.lower().endswith(TARGET_EXTS):
                    files.append(os.path.join(base, name))
    hits = []
    for path in files:
        try:
            info = PE(path).versions()
        except Exception:  # noqa: BLE001
            continue
        if info['os'] > (min_major, min_minor):
            hits.append((path, info))
    print('scanned: %s' % root)
    print('images declaring an OS version above %d.%d: %d / %d' % (min_major, min_minor, len(hits), len(files)))
    for path, info in hits:
        print('  OS %d.%d  sub %d.%d  %s' % (info['os'][0], info['os'][1], info['subsystem'][0], info['subsystem'][1], path))
    return 1 if hits else 0


USAGE = __doc__


def main(argv):
    if len(argv) < 3:
        print(USAGE)
        return 2
    cmd, rest = argv[1], argv[2:]
    if cmd == 'version':
        return cmd_version(rest)
    if cmd == 'imports':
        return cmd_imports(rest)
    if cmd == 'scan':
        root = rest[0]
        major = int(rest[1]) if len(rest) > 1 else 6
        minor = int(rest[2]) if len(rest) > 2 else 1
        return cmd_scan(root, major, minor)
    print(USAGE)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
