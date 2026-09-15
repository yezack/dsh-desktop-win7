@echo off
rem Launch DSH Desktop with the LAN proxy environment it needs on this VM,
rem and capture the main/host process output so stalls can be diagnosed.
set HTTP_PROXY=http://192.168.17.1:7897
set HTTPS_PROXY=http://192.168.17.1:7897
set http_proxy=http://192.168.17.1:7897
set https_proxy=http://192.168.17.1:7897
set NODE_USE_ENV_PROXY=1
set NODE_TLS_REJECT_UNAUTHORIZED=0
set ELECTRON_ENABLE_LOGGING=1
set DSH_LOG_LEVEL=debug

"C:\Users\ye\AppData\Local\Programs\DSH Desktop\DSH Desktop.exe" --enable-logging=stderr --v=1 > C:\dsh\dsh-app.log 2>&1
exit /b %errorlevel%
