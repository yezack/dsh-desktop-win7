"""Check whether VxKex NEXT's extension DLLs actually export the symbols a
binary needs on Windows 7."""
import os
import struct
import sys


def cstr(data, off):
    if off is None or off < 0 or off >= len(data):
        return '<bad>'
    end = data.find(b'\0', off)
    if end < 0:
        end = len(data)
    return data[off:end].decode('latin1', 'replace')


class PE(object):
    def __init__(self, path):
        with open(path, 'rb') as f:
            self.data = f.read()
        d = self.data
        e = struct.unpack_from('<I', d, 0x3C)[0]
        coff = e + 4
        nsec = struct.unpack_from('<H', d, coff + 2)[0]
        size_opt = struct.unpack_from('<H', d, coff + 16)[0]
        opt = coff + 20
        self.pe32plus = struct.unpack_from('<H', d, opt)[0] == 0x20B
        dd_off = opt + (112 if self.pe32plus else 96)
        self.dirs = [struct.unpack_from('<II', d, dd_off + i * 8) for i in range(16)]
        sec_off = opt + size_opt
        self.sections = []
        for i in range(nsec):
            o = sec_off + i * 40
            vsize, vaddr, rawsize, rawptr = struct.unpack_from('<IIII', d, o + 8)
            self.sections.append((vaddr, vsize, rawptr, rawsize))

    def rva2off(self, rva):
        for vaddr, vsize, rawptr, rawsize in self.sections:
            if vaddr <= rva < vaddr + max(vsize, rawsize):
                off = rawptr + (rva - vaddr)
                return off if off < len(self.data) else None
        return None

    def export_names(self):
        names = set()
        rva, size = self.dirs[0]
        if not rva:
            return names
        o = self.rva2off(rva)
        if o is None:
            return names
        f = struct.unpack_from('<IIHHIIIIIII', self.data, o)
        base, nfunc, nnames = f[5], f[6], f[7]
        addr_names, addr_ords = f[9], f[10]
        ao = self.rva2off(addr_names)
        oo = self.rva2off(addr_ords)
        if ao is not None:
            for i in range(min(nnames, 400000)):
                nrva = struct.unpack_from('<I', self.data, ao + i * 4)[0]
                names.add(cstr(self.data, self.rva2off(nrva)))
        if oo is not None:
            for i in range(min(nfunc, 400000)):
                names.add('#%d' % (base + i))
        return names


NEEDED = {
    'GetAddrInfoExCancel': 'WS2_32.dll',
    'DiscardVirtualMemory': 'KERNEL32.dll',
    'GetCurrentPackageFullName': 'KERNEL32.dll',
    'GetPackageFamilyName': 'KERNEL32.dll',
    'GetPackagePathByFullName': 'KERNEL32.dll',
    'GetPackagesByPackageFamily': 'KERNEL32.dll',
    'GetProcessInformation': 'KERNEL32.dll',
    'GetProcessMitigationPolicy': 'KERNEL32.dll',
    'GetSystemTimePreciseAsFileTime': 'KERNEL32.dll',
    'PrefetchVirtualMemory': 'KERNEL32.dll',
    'SetProcessInformation': 'KERNEL32.dll',
    'SetProcessMitigationPolicy': 'KERNEL32.dll',
    'SetThreadInformation': 'KERNEL32.dll',
    # the two the Node 24 runtime needs
    'EventSetInformation': 'ADVAPI32.dll',
}

KEXDIR = r'C:\Program Files\VxKex'

all_exports = {}
for root, dirs, files in os.walk(KEXDIR):
    for n in sorted(files):
        if not n.lower().endswith('.dll'):
            continue
        p = os.path.join(root, n)
        try:
            ex = PE(p).export_names()
        except Exception as e:
            print('  (skip %s: %s)' % (n, e))
            continue
        if ex:
            all_exports[os.path.relpath(p, KEXDIR)] = ex

print('=== VxKex DLLs that provide exports ===')
for k in sorted(all_exports):
    print('  %-40s %5d exports' % (k, len(all_exports[k])))

print('')
print('=== coverage of the symbols our binaries need ===')
providers = []
for sym, dll in sorted(NEEDED.items()):
    hits = [k for k, ex in all_exports.items() if sym in ex]
    status = 'OK  ' if hits else 'MISS'
    print('  %s %-32s from %-14s -> %s' % (status, sym, dll, ', '.join(hits) if hits else 'NOT PROVIDED'))
    if hits:
        providers.append(sym)

print('')
print('provided: %d / %d' % (len(providers), len(NEEDED)))
print('== done ==')
