"""Resolve a Windows 7 update from the Microsoft Update Catalog and download it.

Usage: kb.py KB2670838 [x64]
"""
import json
import re
import ssl
import sys
import urllib.parse
import urllib.request

PROXY = 'http://192.168.17.1:7897'
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
opener = urllib.request.build_opener(
    urllib.request.ProxyHandler({'http': PROXY, 'https': PROXY}),
    urllib.request.HTTPSHandler(context=ctx),
)
opener.addheaders = [('User-Agent', 'Mozilla/5.0 (Windows NT 6.1; Win64; x64)')]

CATALOG = 'https://www.catalog.update.microsoft.com/'


def get(url):
    return opener.open(url, timeout=90).read().decode('utf-8', 'replace')


def post_form(url, fields):
    req = urllib.request.Request(url, data=urllib.parse.urlencode(fields).encode())
    req.add_header('User-Agent', 'Mozilla/5.0 (Windows NT 6.1; Win64; x64)')
    req.add_header('Content-Type', 'application/x-www-form-urlencoded')
    return opener.open(req, timeout=90).read().decode('utf-8', 'replace')


kb = sys.argv[1] if len(sys.argv) > 1 else 'KB2670838'
arch = sys.argv[2] if len(sys.argv) > 2 else 'x64'

html = get(CATALOG + 'Search.aspx?q=' + urllib.parse.quote(kb))

# rows look like: <tr id="<guid>_R1" ...> ... <td>...title...</td>
rows = re.findall(r'<tr[^>]*id="([0-9a-fA-F\-]{36})_R\d"[^>]*>(.*?)</tr>', html, re.S)
print('catalog rows for %s: %d' % (kb, len(rows)))

candidates = []
for guid, row in rows:
    text = re.sub(r'<[^>]+>', ' ', row)
    text = re.sub(r'\s+', ' ', text).strip()
    if arch.lower() not in text.lower():
        continue
    candidates.append((guid, text))

for guid, text in candidates:
    print('  [%s] %s' % (guid, text[:160]))

if not candidates:
    print('no %s candidate found' % arch)
    sys.exit(2)

results = []
for guid, text in candidates:
    payload = json.dumps([{'size': 0, 'updateID': guid, 'uidInfo': guid}])
    body = post_form(CATALOG + 'DownloadDialog.aspx', {
        'updateIDs': payload,
        'updateIDsBlockedForImport': '',
        'wsusApiPresent': '',
        'contentImport': '',
        'sku': '',
        'serverName': '',
        'ssl': '',
        'portNumber': '',
        'version': '',
    })
    urls = re.findall(r"downloadInformation\[\d+\]\.files\[\d+\]\.url\s*=\s*'([^']+)'", body)
    for u in urls:
        if u.lower().endswith('.msu'):
            results.append((guid, u))

print('')
print('download URLs:')
for guid, u in results:
    print('  %s' % u)

if not results:
    print('no .msu url resolved')
    sys.exit(3)

out = sys.argv[3] if len(sys.argv) > 3 else (r'C:\dsh\pkg\%s_%s.msu' % (kb, arch))
url = results[0][1]
print('')
print('downloading ->', out)
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
import os
os.replace(tmp, out)
print('bytes:', os.path.getsize(out))
print('== done ==')
