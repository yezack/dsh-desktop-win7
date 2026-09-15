"""Fetch an official Node.js win-x64 build and extract it (guest-side helper)."""
import os
import shutil
import ssl
import sys
import urllib.request
import zipfile

PROXY = 'http://192.168.17.1:7897'
ROOT = r'C:\dsh'
PKG = os.path.join(ROOT, 'pkg')

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


def fetch(url, out):
    tmp = out + '.part'
    with opener.open(url, timeout=900) as r, open(tmp, 'wb') as f:
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
    os.replace(tmp, out)


version = sys.argv[1] if len(sys.argv) > 1 else 'v24.14.0'
dest_name = 'node24-off' if version.startswith('v24') else ('node22-off' if version.startswith('v22') else 'node-off')
DEST = os.path.join(ROOT, dest_name)

zip_name = 'node-%s-win-x64.zip' % version
zip_path = os.path.join(PKG, zip_name)
url = 'https://nodejs.org/dist/%s/%s' % (version, zip_name)

if not os.path.isfile(zip_path) or os.path.getsize(zip_path) < 20000000:
    print('downloading', url)
    fetch(url, zip_path)
print('zip bytes:', os.path.getsize(zip_path))

if os.path.isdir(DEST):
    shutil.rmtree(DEST)
os.makedirs(DEST)
with zipfile.ZipFile(zip_path) as z:
    z.extractall(PKG)

extracted = None
for n in os.listdir(PKG):
    p = os.path.join(PKG, n)
    if os.path.isdir(p) and n.lower().startswith('node-%s-win-x64' % version):
        extracted = p
print('extracted:', extracted)
if extracted:
    for item in os.listdir(extracted):
        shutil.move(os.path.join(extracted, item), os.path.join(DEST, item))
    shutil.rmtree(extracted, ignore_errors=True)

print('node.exe size:', os.path.getsize(os.path.join(DEST, 'node.exe')))
print('DEST=%s' % DEST)
