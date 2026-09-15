import json
import os
import ssl
import sys
import urllib.request

PROXY = 'http://192.168.17.1:7897'
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
opener = urllib.request.build_opener(
    urllib.request.ProxyHandler({'http': PROXY, 'https': PROXY}),
    urllib.request.HTTPSHandler(context=ctx),
)
opener.addheaders = [('User-Agent', 'dsh-probe')]


def api(url):
    return json.loads(opener.open(url, timeout=60).read().decode('utf-8', 'replace'))


def find_asset(repo, tag_contains, name_contains):
    for rel in api('https://api.github.com/repos/%s/releases?per_page=100' % repo):
        if tag_contains and tag_contains not in rel.get('tag_name', ''):
            continue
        for a in rel.get('assets', []):
            if name_contains in a['name']:
                return a
    return None


def fetch(url, out):
    tmp = out + '.part'
    with opener.open(url, timeout=300) as r, open(tmp, 'wb') as f:
        total = int(r.headers.get('Content-Length') or 0)
        done = 0
        while True:
            chunk = r.read(262144)
            if not chunk:
                break
            f.write(chunk)
            done += len(chunk)
    if total and done != total:
        raise RuntimeError('size mismatch got=%d want=%d' % (done, total))
    os.replace(tmp, out)
    return done


cmd = sys.argv[1]
if cmd == 'rel':
    for repo in sys.argv[2:]:
        print('=== %s ===' % repo)
        try:
            for rel in api('https://api.github.com/repos/%s/releases?per_page=100' % repo):
                print('  tag:', rel.get('tag_name'), '|', (rel.get('name') or '')[:70])
                for a in rel.get('assets', []):
                    print('      %-58s %7s MB' % (a['name'], round(a['size'] / 1048576.0, 2)))
        except Exception as e:
            print('  ERR:', type(e).__name__, e)
elif cmd == 'get':
    repo, tag, name, out = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
    a = find_asset(repo, tag, name)
    if not a:
        print('ASSET NOT FOUND', repo, tag, name)
        sys.exit(2)
    print('asset:', a['name'], round(a['size'] / 1048576.0, 1), 'MB')
    n = fetch(a['browser_download_url'], out)
    print('downloaded %d bytes -> %s' % (n, out))
elif cmd == 'url':
    url, out = sys.argv[2], sys.argv[3]
    n = fetch(url, out)
    print('downloaded %d bytes -> %s' % (n, out))
else:
    print('usage: dl.py get <repo> <tag> <name> <out> | dl.py url <url> <out>')
    sys.exit(1)
