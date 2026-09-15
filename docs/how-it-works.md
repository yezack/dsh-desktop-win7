# How it works

Everything here is measured, not assumed. This document records what was
actually observed on a Windows 7 SP1 x64 virtual machine (build 7601, 8 GB RAM,
only KB2533623 / KB2534111 / KB976902 installed) with **DSH Desktop 2.0.10**,
which ships **Electron 43.3.0** (Chromium 140, Node 24.18.1).

---

## Gate 1 — missing Windows 8+ APIs

`tools/pe_inspect.py imports <binary>` diffs every statically imported symbol
against the exports actually present in the machine's `System32`. The gaps are
surprisingly small:

| Binary | Missing | Symbols |
|---|---|---|
| official **Node v24.14.0** | **2** | `ADVAPI32!EventSetInformation`, `KERNEL32!GetSystemTimePreciseAsFileTime` |
| **Electron 43** (`DSH Desktop.exe`) | **13** | `WS2_32!GetAddrInfoExCancel`; `KERNEL32!` `DiscardVirtualMemory`, `GetCurrentPackageFullName`, `GetPackageFamilyName`, `GetPackagePathByFullName`, `GetPackagesByPackageFamily`, `GetProcessInformation`, `GetProcessMitigationPolicy`, `GetSystemTimePreciseAsFileTime`, `PrefetchVirtualMemory`, `SetProcessInformation`, `SetProcessMitigationPolicy`, `SetThreadInformation` |

`GetSystemTimePreciseAsFileTime` is the interesting one: Windows 7 *does* have
the older `GetSystemTimeAsFileTime` with an identical signature, which is what
the community Win7 Node builds substitute at source level.

### Solution: VxKex NEXT

[VxKex NEXT](https://github.com/YuZhouRen86/VxKex-NEXT) injects `kexdll.dll`
into a per-program process via the IFEO `VerifierDlls` mechanism and redirects
the missing imports to its own `KxBase` / `KxAdvapi` / `KxNet` / `KxUser` DLLs.
`tools/kex_coverage.py` verifies coverage against the symbols above:

```
Kex64\KxAdvapi.dll   1645 exports
Kex64\KxBase.dll     3850 exports
Kex64\KxNet.dll      1208 exports
...
provided: 14 / 14
```

### Automating the install (the gotchas)

The published installer is a **7-Zip SFX**, and its payload `KexSetup.exe` is a
GUI program. Two non-obvious requirements were found by trial:

1. **`/S` does nothing.** The supported silent switch is `/SILENTUNATTEND`.
2. **`SetupPrerequisitesDontShowAgain` must be pre-set**, otherwise the
   prerequisite task dialog still appears in silent mode and blocks forever:

   ```bat
   reg add "HKCU\Software\VXsoft\VxKex" /v SetupPrerequisitesDontShowAgain /t REG_DWORD /d 1 /f
   ```
3. **`KexSetup.exe` must be started with its own directory as the working
   directory** — it locates `Core64\`, `Kex64\` etc. relative to itself, and
   silently does nothing otherwise:

   ```bat
   cd /d <vxkex-unpacked>
   KexSetup.exe /SILENTUNATTEND /KEXDIR:"C:\Program Files\VxKex"
   ```

Per-program enabling is scriptable, because `KexCfg` has a command line:

```bat
"C:\Program Files\VxKex\Core64\KexCfg.exe" /EXE:"<abs path>\DSH Desktop.exe" ^
    /ENABLE:TRUE /WINVERSPOOF:WIN10
```

`/WINVERSPOOF` matters for Chromium, which refuses to start on a Windows version
it does not recognise.

---

## Gate 2 — the PE header declares Windows 10

After VxKex was enabled, `DSH Desktop.exe` **still would not start**: no
Chromium log lines at all, no `Application Error` event, the process simply
disappeared. The host `cmd.exe` that launched it hung waiting on a process that
was already gone.

The breakthrough was forcing an exit code out of the loader with
`Start-Process -PassThru -Wait`, which surfaced:

```
EXCEPTION: 由于出现以下错误，无法执行操作: %1 不是有效的 Win32 应用程序。
                              (ERROR_BAD_EXE_FORMAT / STATUS_INVALID_IMAGE_FORMAT / 0xC000007B)
```

`tools/pe_inspect.py version` compared the two binaries:

| Binary | OS version | Subsystem version |
|---|---|---|
| `node.exe` (Node 24, **works**) | 6.0 | 6.0 |
| `DSH Desktop.exe` (Electron 43, **fails**) | **10.0** | **10.0** |

**Windows' loader refuses an image whose optional header declares an OS version
newer than the running OS.** That happens before a single instruction of the
program runs — which is exactly why there was no log, no crash event and no
error dialog.

### The fix: four header fields, eight bytes

```
PE optional header, PE32+ layout
  opt+40  MajorOperatingSystemVersion   WORD   10 -> 6
  opt+42  MinorOperatingSystemVersion   WORD    0 -> 1
  opt+48  MajorSubsystemVersion         WORD   10 -> 6
  opt+50  MinorSubsystemVersion         WORD    0 -> 1
```

`tools/pe_downlevel.py` implements this:

```powershell
python tools/pe_downlevel.py scan     "C:\path\to\app"        # list offenders
python tools/pe_downlevel.py patchdir "C:\path\to\app" 6 1    # patch top level, keep .orig-osver backups
python tools/pe_downlevel.py patch    "<one file>" 6 1
```

Eight x64 files need it:

```
DSH Desktop.exe   d3dcompiler_47.dll   dxcompiler.dll      ffmpeg.dll
libEGL.dll        libGLESv2.dll        vk_swiftshader.dll  vulkan-1.dll
```

A recursive scan also reports twelve **arm64** binaries (`@img/sharp-win32-arm64`,
`node-pty/prebuilds/win32-arm64`, …) at OS 6.2. They are never loaded on x64, so
`patchdir` deliberately operates on one level only and ignores them.

---

## Verification after both gates

```
ELECTRON_RUN_AS_NODE=1 "DSH Desktop.exe" --version                 -> v24.18.1
ELECTRON_RUN_AS_NODE=1 "DSH Desktop.exe" "...\desktop-cli.js" --version
                                                                   -> 0.1.5-rc.2
plain node 24 + @deepseek-ai/dsh --profile web --dump-default-config
                                                                   -> full plugin tree
```

The desktop app's own startup pipeline (from
`%APPDATA%\DSH Desktop\lifecycle-events\startup.jsonl`) runs to completion:

```
electron-ready      ✅    65 ms
shell-environment   ✅
runtime-bootstrap   ✅    12 ms
profile-selection   ✅
profile-composition ✅   285 ms      <- plugin layers composed
runtime-bootstrap   ✅   175 ms
host-boot           ✅  6308 ms      <- DSH host up
renderer-startup    ✅  2508 ms      <- UI rendered
health-commit       ✅   531 ms
```

and the host serves the UI on `127.0.0.1:43120`.

The only Chromium log line of note is benign:

```
ERROR:base\trace_event\trace_logging_minimal_win.cc:25] Provider registration failure
```

— that is the ETW `EventSetInformation` call landing on the VxKex shim.

---

## Notes worth keeping

### The folder picker is pinned by the desktop shell

`dsh-host-directory-picker-auto` resolves to `native` on `win32`, but the
Electron shell *replaces* it with the **browse** pair and serves the real OS
dialog itself through its own route:

```
resources/app/lib/profile-pZhrTizp.js
  DIRECTORY_PICKER_ROW_ID = "directory-picker"
  BROWSE_PICKER_BACKEND   = "@deepseek-ai/dsh-host-directory-picker-browse"
  if (!rows.has(DIRECTORY_PICKER_ROW_ID)) throw ... "desktop profile has no directory-picker row"

resources/app/lib/src-BnqQw2mw.js
  POST /_dsh/desktop/pick-directory   ->  runtime.pickDirectory()  ->  dialog.showOpenDialog(...)
```

Do **not** try to pin `dsh-host-directory-picker-native` in the profile patch
layer: it collides with the already-registered `directoryPicker` service and the
whole plugin tree fails to load (`host-boot` fails). The Win32 dialog worker
itself is fine on Windows 7 — `tools/probe-win32-dialog.js` drives it standalone
and reaches `{"kind":"showing"}` (i.e. the COM `IFileOpenDialog` was created and
`Show()` was entered).

### Offline network

On an isolated Win7 box the only thing DSH needs the network for is the model
API. If the machine reaches the internet through a proxy, start the app with the
proxy in its environment (`scripts/start-dsh-win7.cmd`) — Chromium reads the
WinINET settings, Node-side code needs `HTTP_PROXY` / `HTTPS_PROXY` (plus
`NODE_USE_ENV_PROXY=1` on modern Node).
Any MCP server that is normally launched with `npx` should be vendored locally
and referenced by absolute path — see `scripts/vendor-cdp-mcp.cmd`.

### Running a GUI app from an SSH session

Processes started over SSH live in **session 0**, which has no visible desktop:
the window exists but nobody can see it. To put a program on the logged-on
user's desktop, register a scheduled task with an **interactive token**
(`TASK_LOGON_INTERACTIVE_TOKEN`) — `scripts/run-in-session.ps1` does exactly
that. Launching from the desktop shortcut avoids the problem entirely.
