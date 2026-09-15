# DSH Desktop for Windows 7

让 **DSH Desktop 官方版**在 **Windows 7 SP1 x64** 上直接可用 —— **不重新编译 DSH，也不重新编译 Electron**。

> 官方 DSH Desktop 2.0.10 依赖 **Electron 43 / Chromium 140**，而 [Chromium 110 起就不再支持 Windows 7](https://electronjs.org/blog/windows-7-to-8-1-deprecation-notice)，
> 加载器会直接拒绝其主程序。本仓库用**产物级适配**绕开这一点。

## 快速开始

1. 到 [Releases](../../releases) 下载 `DSH-Desktop-<版本>-Win7-portable.zip`
2. 解压到任意目录（**路径不要含中文**，建议 `C:\DSH-Win7`）
3. 右键 `install.cmd` → **以管理员身份运行**
4. 完成后双击桌面上的 **DSH Desktop** 快捷方式

目标机要求：**Windows 7 SP1 x64** + **KB2533623**（DllDirectories 更新）+ **管理员权限**。

## 为什么原生跑不起来：两道门槛

### 门槛 1 — 缺少 Windows 8+ 的 API

用 PE 导入表比对实测，缺的符号其实很少：

| 二进制 | 缺失符号数 | 缺哪些 |
|---|---|---|
| 官方 Node v24.14.0 | **2** | `ADVAPI32!EventSetInformation`、`KERNEL32!GetSystemTimePreciseAsFileTime` |
| **Electron 43**（`DSH Desktop.exe`） | **13** | `WS2_32!GetAddrInfoExCancel`；`KERNEL32!` 的 `DiscardVirtualMemory`、`Get*Package*`×4、`GetProcessInformation`、`Get/SetProcessMitigationPolicy`、`GetSystemTimePreciseAsFileTime`、`PrefetchVirtualMemory`、`SetProcessInformation`、`SetThreadInformation` |

解法：**[VxKex NEXT](https://github.com/YuZhouRen86/VxKex-NEXT)** —— 按程序注入 `kexdll.dll`（IFEO `VerifierDlls`），把缺失导入重定向到自带的 `KxBase` / `KxAdvapi` / `KxNet` / `KxUser` 等扩展 DLL。本仓库实测覆盖率 **14/14**。

### 门槛 2 — PE 头声明的 OS 版本过高（真正的大魔王）

启用 VxKex 之后 Electron **依然起不来**：无日志、无崩溃记录、进程瞬间消失。
`Start-Process` 报 **`%1 不是有效的 Win32 应用程序`**（`ERROR_BAD_EXE_FORMAT` / `STATUS_INVALID_IMAGE_FORMAT` / `0xC000007B`）。

根因是 **Windows 加载器会拒绝「可选头里声明的 OS 版本高于当前系统」的映像**：

| 二进制 | 声明 OS 版本 | 子系统版本 | 结果 |
|---|---|---|---|
| `node.exe`（Node 24） | 6.0 | 6.0 | ✅ 加载 |
| `DSH Desktop.exe`（Electron 43） | **10.0** | **10.0** | ❌ 加载器拒绝 |

解法：把 PE 可选头的 `Major/MinorOperatingSystemVersion`(opt+40/+42) 与
`Major/MinorSubsystemVersion`(opt+48/+50) 改成 **6.1**。只需改 8 个字节，见 [`tools/pe_downlevel.py`](tools/pe_downlevel.py)。

需打补丁的是 **8 个 x64 文件**（其余 12 个是 arm64 产物，x64 上永不加载，可忽略）：

```
DSH Desktop.exe   d3dcompiler_47.dll   dxcompiler.dll      ffmpeg.dll
libEGL.dll        libGLESv2.dll        vk_swiftshader.dll  vulkan-1.dll
```

## 仓库结构

```
tools/
  pe_downlevel.py        核心：PE 头降级（可 scan / patch / patchdir）
  pe_inspect.py          诊断：导入缺口比对 + PE 版本输出
  kex_coverage.py        校验 VxKex 扩展 DLL 是否覆盖所需符号
  probe-win32-dialog.js  诊断：单独驱动 Win32 文件夹对话框 worker
config/
  cordis.patch.win7.yml  桌面 profile 的 Win7 patch 片段（含离线 MCP）
  pnpm-workspace.win7.yml
scripts/
  build-portable.ps1     构建便携包（下载 → 解包 → 打补丁 → 组装 → 压缩）
  install-portable.ps1   目标机一键安装（装 VxKex + 启用 + 建快捷方式）
  verify-win7.ps1        安装后自检
  run-in-session.ps1     把程序投递到当前已登录的桌面会话（SSH 场景用）
  start-dsh-win7.cmd     带代理环境变量启动 DSH
  pnpm-shim.cmd          DSH plugin 命令需要的 pnpm 包装
  vendor-cdp-mcp.cmd     离线 vendoring chrome-devtools-mcp
  offline-*.py           离线中转工具（走宿主代理下载）
docs/
  how-it-works.md        原理与验证记录
  deployment.md          完整实测记录（含每个坑位）
```

## 自己构建

```powershell
# 需要 python3 + 7-Zip（缺了脚本会自己下载 7zr）
pwsh -File scripts/build-portable.ps1 -DshVersion 2.0.10
# 产物：dist/DSH-Desktop-2.0.10-Win7-portable.zip
```

也可以直接用 GitHub Actions：`Actions → Build Win7 portable → Run workflow`，
或打 tag（`v*`）自动发布会附上 Release asset。

## 已知限制

- ⚠️ **DSH 自动升级后必须重新打补丁** —— 新 exe 的 PE 头会变回 10.0。重跑 `install.cmd` 即可（脚本幂等）。若要彻底避免，请在设置里关闭自动更新。
- ⚠️ 修改二进制会**使 Electron 的数字签名失效**（不影响加载，但 SmartScreen 可能提示）。
- ⚠️ **VxKex NEXT 上游开发已暂停至 2027-08**，新的 Win10-only API 缺口短期内不会被补。
- ⚠️ 未经平台更新（KB2670838）时 Chromium 的 GPU 路径会降级为软件渲染；本适配在实测机上以 `--use-gl=disabled` 路径正常运行。
- 未在 Windows 8 / 8.1 上验证。
- 文件夹选择器：桌面端自己钉的是 browse（应用内）后端，OS 对话框由 Electron 主进程经 `/_dsh/desktop/pick-directory` 提供。**不要**在 profile patch 里再钉 `dsh-host-directory-picker-native`，会与服务注册冲突导致 host-boot 失败。

## 许可与归属

- 本仓库的脚本与文档：**MIT**（见 [LICENSE](LICENSE)）
- [DSH Desktop](https://github.com/anywhere-labs/dsh-desktop)：版权归 anywhere-labs
- [VxKex NEXT](https://github.com/YuZhouRen86/VxKex-NEXT)：版权归 YuZhouRen86
- 本仓库**不再分发**上述项目的二进制；构建脚本只从各自官方 Release 下载。详见 [NOTICE](NOTICE)。
