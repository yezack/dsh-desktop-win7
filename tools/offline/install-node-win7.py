"""Install the Windows 7 capable Node.js v20.19.2 runtime into C:\\dsh\\node."""
import os
import shutil
import ssl
import sys
import urllib.request
import zipfile

PROXY = 'http://192.168.17.1:7897'
ROOT = r'C:\dsh'
PKG = os.path.join(ROOT, 'pkg')
DEST = os.path.join(ROOT, 'node')
URL = ('https://raw.githubusercontent.com/vladimir-andreevich/node.js-windows-7'
       '/main/v20/node-v20.19.2-win-x64.zip')

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
opener = urllib.request.build_opener(
    urllib.request.ProxyHandler({'http': PROXY, 'https': PROXY}),
    urllib.request.HTTPSHandler(context=ctx),
)
opener.addheaders = [('User-Agent', 'dsh-probe')]

for d in (ROOT, PKG):
    if not os.path.isdir(d):
        os.makedirs(d)

zip_path = os.path.join(PKG, 'node-v20.19.2-win-x64.zip')
if not os.path.isfile(zip_path) or os.path.getsize(zip_path) < 20000000:
    print('downloading', URL)
    tmp = zip_path + '.part'
    with opener.open(URL, timeout=600) as r, open(tmp, 'wb') as f:
        total = int(r.headers.get('Content-Length') or 0)
        done = 0
        while True:
            chunk = r.read(262144)
            if not chunk:
                break
            f.write(chunk)
            done += len(chunk)
            if total:
                sys.stdout.write('\r  %5.1f%%  %d/%d' % (done * 100.0 / total, done, total))
                sys.stdout.flush()
    print('')
    if total and done != total:
        raise RuntimeError('size mismatch got=%d want=%d' % (done, total))
    os.replace(tmp, zip_path)
print('zip bytes:', os.path.getsize(zip_path))

if os.path.isdir(DEST):
    shutil.rmtree(DEST)
os.makedirs(DEST)

with zipfile.ZipFile(zip_path) as z:
    z.extractall(PKG)

extracted = None
for n in os.listdir(PKG):
    p = os.path.join(PKG, n)
    if os.path.isdir(p) and n.lower().startswith('node-v20'):
        extracted = p
print('extracted dir:', extracted)
if extracted:
    for item in os.listdir(extracted):
        shutil.move(os.path.join(extracted, item), os.path.join(DEST, item))
    shutil.rmtree(extracted, ignore_errors=True)

print('node.exe :', os.path.isfile(os.path.join(DEST, 'node.exe')))
print('npm.cmd  :', os.path.isfile(os.path.join(DEST, 'npm.cmd')))
print('== done ==')
