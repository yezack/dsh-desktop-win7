@echo off
setlocal
set HTTP_PROXY=http://192.168.17.1:7897
set HTTPS_PROXY=http://192.168.17.1:7897
set npm_config_proxy=http://192.168.17.1:7897
set npm_config_https_proxy=http://192.168.17.1:7897
set npm_config_strict_ssl=false
set NODE_TLS_REJECT_UNAUTHORIZED=0
set PATH=C:\dsh\node24-off;%PATH%

if not exist C:\dsh\mcp\chrome-devtools mkdir C:\dsh\mcp\chrome-devtools
cd /d C:\dsh\mcp\chrome-devtools

echo === npm install chrome-devtools-mcp ===
call npm install chrome-devtools-mcp --no-audit --no-fund
echo NPM_EXIT=%errorlevel%

echo === package metadata ===
call node -e "const p=require('C:/dsh/mcp/chrome-devtools/node_modules/chrome-devtools-mcp/package.json'); console.log('version:',p.version); console.log('bin:',JSON.stringify(p.bin)); console.log('main:',p.main); console.log('exports:',JSON.stringify(p.exports)); console.log('engines:',JSON.stringify(p.engines))"

echo === package dir ===
dir /b node_modules\chrome-devtools-mcp 2>&1

echo === .bin ===
dir /b node_modules\.bin 2>&1

echo === done ===
