"""Lower a PE image's declared OS / subsystem version so Windows 7 will load it.

Windows' loader refuses an image whose optional-header OS version is newer than
the running OS, failing with STATUS_INVALID_IMAGE_FORMAT (0xC000007B,
"not a valid Win32 application") before any code executes.

Usage:
  pe_downlevel.py scan     <dir-or-file> [min_major] [min_minor]   list offenders
  pe_downlevel.py patch    <file> [major] [minor]                  back up and patch one file
  pe_downlevel.py patchdir <dir>  [major] [minor]                  patch every offending file at the top level only
"""
import os
import struct
import sys

FIELDS = {
    'os_major': 40,
    'os_minor': 42,
    'sub_major': 48,
    'sub_minor': 50,
}
TARGET_EXTS = ('.exe', '.dll', '.node')


def parse(path):
    with open(path, 'rb') as f:
        d = f.read()
    if len(d) < 0x40 or d[:2] != b'MZ':
        return None
    e = struct.unpack_from('<I', d, 0x3C)[0]
    if e + 0x40 > len(d) or d[e:e + 4] != b'PE\0\0':
        return None
    coff = e + 4
    size_opt = struct.unpack_from('<H', d, coff + 16)[0]
    opt = coff + 20
    magic = struct.unpack_from('<H', d, opt)[0]
    if magic not in (0x10B, 0x20B):
        return None
    vals = {}
    for k, off in FIELDS.items():
        vals[k] = struct.unpack_from('<H', d, opt + off)[0]
    vals['opt'] = opt
    vals['magic'] = magic
    return vals


def offenders(root, min_major=6, min_minor=1):
    files = []
    if os.path.isfile(root):
        files = [root]
    else:
        for base, dirs, names in os.walk(root):
            for n in names:
                if n.lower().endswith(TARGET_EXTS):
                    files.append(os.path.join(base, n))
    out = []
    for p in files:
        try:
            v = parse(p)
        except Exception:
            continue
        if not v:
            continue
        if (v['os_major'], v['os_minor']) > (min_major, min_minor):
            out.append((p, v))
    return out


cmd = sys.argv[1] if len(sys.argv) > 1 else 'scan'
arg = sys.argv[2] if len(sys.argv) > 2 else r'C:\Users\ye\AppData\Local\Programs\DSH Desktop'

if cmd == 'scan':
    hits = offenders(arg)
    print('scanned root: %s' % arg)
    print('files declaring a newer-than-6.1 OS version: %d' % len(hits))
    for p, v in hits:
        print('  OS %d.%d sub %d.%d  %s' % (v['os_major'], v['os_minor'], v['sub_major'], v['sub_minor'], p))
    print('== done ==')
elif cmd == 'patch':
    major = int(sys.argv[3]) if len(sys.argv) > 3 else 6
    minor = int(sys.argv[4]) if len(sys.argv) > 4 else 1
    targets = [p for p in sys.argv[2:] if os.path.isfile(p)]
    for p in targets:
        v = parse(p)
        if not v:
            print('not a PE: %s' % p)
            continue
        backup = p + '.orig-osver'
        if not os.path.exists(backup):
            import shutil
            shutil.copy2(p, backup)
            print('backup -> %s' % backup)
        with open(p, 'r+b') as f:
            opt = v['opt']
            f.seek(opt + FIELDS['os_major'])
            f.write(struct.pack('<HH', major, minor))
            f.seek(opt + FIELDS['sub_major'])
            f.write(struct.pack('<HH', major, minor))
        nv = parse(p)
        print('patched %s' % os.path.basename(p))
        print('  before: OS %d.%d sub %d.%d' % (v['os_major'], v['os_minor'], v['sub_major'], v['sub_minor']))
        print('  after : OS %d.%d sub %d.%d' % (nv['os_major'], nv['os_minor'], nv['sub_major'], nv['sub_minor']))
    print('== done ==')
elif cmd == 'patchdir':
    # non-recursive: patch every top-level offender in a directory
    major = int(sys.argv[3]) if len(sys.argv) > 3 else 6
    minor = int(sys.argv[4]) if len(sys.argv) > 4 else 1
    for p, v in offenders(arg, 6, 1):
        if os.path.dirname(p) != os.path.abspath(arg):
            continue
        backup = p + '.orig-osver'
        if not os.path.exists(backup):
            import shutil
            shutil.copy2(p, backup)
        with open(p, 'r+b') as f:
            opt = v['opt']
            f.seek(opt + FIELDS['os_major'])
            f.write(struct.pack('<HH', major, minor))
            f.seek(opt + FIELDS['sub_major'])
            f.write(struct.pack('<HH', major, minor))
        nv = parse(p)
        print('patched %-28s OS %d.%d sub %d.%d -> %d.%d / %d.%d'
              % (os.path.basename(p), v['os_major'], v['os_minor'], v['sub_major'], v['sub_minor'],
                 nv['os_major'], nv['os_minor'], nv['sub_major'], nv['sub_minor']))
    print('== done ==')
else:
    print(__doc__)
