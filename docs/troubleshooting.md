# Troubleshooting

Run `verify-win7.ps1` first — it names the failing layer.

---

## "不是有效的 Win32 应用程序" / "not a valid Win32 application"

**The PE header regressed.** This is the signature of an image declaring an OS
version newer than Windows 7 (see [how-it-works.md](how-it-works.md), gate 2).

Almost always caused by a **DSH Desktop auto-update**: the new executables arrive
with `OS version 10.0` again and Windows 7 refuses to load them.

Fix:

```
verify-win7.ps1          # confirms the header
install.cmd              # re-applies everything (idempotent)
```

To stop the churn, turn off automatic updates in DSH Desktop's settings.

---

## The app starts but no window appears

1. Are you launching it over SSH / a service? Processes started in **session 0**
   have no visible desktop. Launch it from a desktop shortcut, or use
   `scripts/run-in-session.ps1` to deliver it to the logged-on session.
2. Check the log:
   `%APPDATA%\DSH Desktop\logs\dsh-<date>.error.log`

---

## Window appears, but nothing renders / black UI

The GPU path is degraded because the **Platform Update (KB2670838)** is not
installed. Confirm:

```powershell
(Get-Item C:\Windows\System32\dxgi.dll).VersionInfo.FileVersion   # 6.1.7601.x = not updated
```

The application already falls back to software rendering. Expect a slower, but
working, UI.

---

## Startup hangs at `profile-composition`

Check `%APPDATA%\DSH Desktop\lifecycle-events\startup.jsonl`. A **failed** stage
carries a reason:

```
{"eventName":"startup.stage.failed","stageId":"host-boot", ...}
```

The matching explanation is in
`%APPDATA%\DSH Desktop\logs\dsh-<date>.error.log`. A concrete example seen in
practice:

```
service "directoryPicker" has been registered at <BrowseDirectoryPicker>
```

→ something added a second directory-picker backend to the profile patch layer.
The desktop shell owns that row; remove your override.

---

## VxKex was installed but nothing changed

Check, in order:

1. `C:\Windows\System32\KexDll.dll` exists (KexSetup puts it there).
2. The IFEO key exists **and has a `VerifierDlls` value**:

   ```
   HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\DSH Desktop.exe
     UseFilter        REG_DWORD  1
     \VxKex_<hash>
       VerifierDlls   REG_SZ     kexdll.dll
       GlobalFlag     REG_DWORD  0x100
   ```

3. **`FilterFullPath` matches where the executable actually is.** VxKex pins the
   absolute path — moving the portable folder after install silently disables
   injection. Re-run `install.cmd`.

---

## `dsh plugin ...` fails with "pnpm not found on PATH"

DSH shells out to a `pnpm` executable. On a machine without pnpm on `PATH`, use
the shim in `scripts/pnpm-shim.cmd` (edit the two paths at the top) and put its
directory on `PATH`.

---

## Profile plugin install fails on a fresh machine

Two causes seen in practice:

1. **Supply-chain policy** (pnpm `minimumReleaseAge`, 24 h). Very recently
   published versions are rejected. Add the exact specifiers pnpm printed to
   `minimumReleaseAgeExclude` in the profile's `pnpm-workspace.yaml`.
2. **`git ls-remote` for an unpinned `github:` dependency** — fails on a machine
   without `git`. Pin the dependency to a full commit SHA:

   ```json
   "@yezack/dsh-ssh": "github:yezack/dsh-ssh-panel#7465e941ec38c855e167e1ef6330661cebc28181"
   ```

   pnpm then fetches the codeload tarball directly and never needs git.

Native build failures (`cpu-features`, `ssh2`'s optional crypto binding) are
**harmless** on a machine without a C++ toolchain — both fall back to pure JS.
`node-pty` matters more, but it ships prebuilds and needs no compiler.

---

## A GUI app disappears instead of opening a dialog

If a helper is spawned as `process.execPath` + a script, remember that under a
packaged Electron app `process.execPath` is the *Electron binary*, not `node`.
Spawned children must inherit `ELECTRON_RUN_AS_NODE=1` or they will start a
second copy of the application instead of running the script.
`tools/probe-win32-dialog.js` demonstrates driving such a helper correctly under
plain Node.
