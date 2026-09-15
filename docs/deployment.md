# Win7 运行 DSH Desktop —— 攻克记录与可复现方案

> 目标：在 **Windows 7 SP1 x64** 上跑起**与本机一致的 DSH Desktop**（2.0.10 + `code` profile 的 12 个插件 + 6 个 MCP + 技能包）。
> 目标机：`vin7_vm` = 192.168.17.132（VM-WIN7-X64）　宿主机：192.168.17.1（VMware VMnet8）

> **这是一份原始实测记录**，保留当时的排查顺序与每个坑位。文中的脚本名是排查阶段的名字，
> 入库后已规范化，对照如下：
>
> | 记录中的名字 | 仓库中的位置 |
> |---|---|
> | `pe-missing.py` / `pe-version.py` | `tools/pe_inspect.py`（`imports` / `version`） |
> | `pe-downlevel.py` | `tools/pe_downlevel.py` |
> | `kex-coverage.py` | `tools/kex_coverage.py` |
> | `dl.py` / `kb.py` / `get-official-node.py` / `node-setup.py` | `tools/offline/` |
> | `probe-dsh-host.ps1` / `probe-win32-dialog.js` | `scripts/verify-win7.ps1` / `tools/probe-win32-dialog.js` |
> | `launch-interactive.ps1` / `run-in-session.ps1` | `scripts/run-in-session.ps1` |
>
> 原理综述见 [how-it-works.md](how-it-works.md)，故障排查见 [troubleshooting.md](troubleshooting.md)。

---

## 一、结果总览

| 能力 | 状态 |
|---|---|
| **官方原版 Node v24.14.0 在 Win7 运行** | ✅ 已实测 |
| **Electron 43 在 Win7 运行**（含其内置 Node v24.18.1） | ✅ **已攻破** |
| DSH desktop-cli（Electron-as-Node） | ✅ 输出 `0.1.5-rc.2` |
| DSH Desktop GUI 主程序启动 | ✅ 5 个 Electron 进程稳定存活，`%APPDATA%\DSH Desktop` 正常创建 |
| DSH 完整插件树（数百 plugin）组合 | ✅ `--profile web --dump-default-config` 全量输出 |
| 进入 `code` profile 并复刻插件/MCP/技能 | ⏳ 待做（配置迁移阶段） |

---

## 二、两道门槛，逐个突破

### 门槛 1：Windows API 缺失 → **VxKex-NEXT 兼容层**

用 PE 导入表比对（`pe-missing.py`）实测出的缺口：

| 二进制 | 缺失符号 | 缺什么 |
|---|---|---|
| 官方 Node v24.14.0 | **2** | `ADVAPI32!EventSetInformation`、`KERNEL32!GetSystemTimePreciseAsFileTime` |
| Electron 43 | **13** | `WS2_32!GetAddrInfoExCancel`；`KERNEL32!` 的 `DiscardVirtualMemory`、`Get*Package*`×4、`GetProcessInformation`、`Get/SetProcessMitigationPolicy`、`GetSystemTimePreciseAsFileTime`、`PrefetchVirtualMemory`、`SetProcessInformation`、`SetThreadInformation` |

**解法：`VxKex-NEXT`**（`github.com/YuZhouRen86/VxKex-NEXT`）—— 按程序注入 `kexdll.dll`（IFEO `VerifierDlls`），把缺失导入重定向到自带的 `KxBase/KxAdvapi/KxNet/KxUser` 等扩展 DLL。
实测覆盖率 **14/14 全中**。

无界面部署（已验证）：

```bat
:: 1) 7z-SFX 安装器无法在 SSH 会话交互，直接解包
7zr.exe x KexSetup_Release_1_2_3_2463.exe -oC:\dsh\kex -y

:: 2) 预置「不再提示前置缺失」，否则静默模式仍弹框卡死
reg add "HKCU\Software\VXsoft\VxKex" /v SetupPrerequisitesDontShowAgain /t REG_DWORD /d 1 /f

:: 3) 必须 cd 到自身目录（否则读不到 Core64/Kex64），静默安装
cd /d C:\dsh\kex
KexSetup.exe /SILENTUNATTEND /KEXDIR:"C:\Program Files\VxKex"

:: 4) 按程序启用（KexCfg 有命令行模式）
"C:\Program Files\VxKex\KexCfg.exe" /EXE:"<exe绝对路径>" /ENABLE:TRUE /WINVERSPOOF:WIN10
```

> KexCfg 完整参数：`/EXE:` `/ENABLE:` `/DISABLEFORCHILD:` `/DISABLEAPPSPECIFIC:` `/WINVERSPOOF:(NONE|WIN7SP1|WIN8|WIN81|WIN10|WIN11)` `/STRONGSPOOF:<hex>`

### 门槛 2（真正的大魔王）：PE 头声明的 OS 版本过高 → **二进制降级补丁**

**症状**：启用 VxKex 后 Electron 仍然「无日志、无崩溃记录、瞬间消失」；`Start-Process` 报
`%1 不是有效的 Win32 应用程序`（**`ERROR_BAD_EXE_FORMAT` / `STATUS_INVALID_IMAGE_FORMAT` / `0xC000007B`**）。

**根因**：Windows 加载器会拒绝「可选头里声明的 OS 版本高于当前系统」的映像。实测对比：

| 二进制 | 声明 OS 版本 | 子系统版本 | 结果 |
|---|---|---|---|
| `node.exe`（Node 24） | 6.0 | 6.0 | ✅ 加载 |
| `DSH Desktop.exe`（Electron 43） | **10.0** | **10.0** | ❌ 加载器拒绝 |

**解法**：把 PE 可选头的 `Major/MinorOperatingSystemVersion`(opt+40/+42) 与 `Major/MinorSubsystemVersion`(opt+48/+50) 改成 `6.1`。工具：`pe-downlevel.py`。

需打补丁的是 **8 个 x64 关键文件**（其余 12 个是 arm64 产物，x64 上永不加载，可忽略）：

```
DSH Desktop.exe   d3dcompiler_47.dll   dxcompiler.dll      ffmpeg.dll
libEGL.dll        libGLESv2.dll        vk_swiftshader.dll  vulkan-1.dll
```

```bat
python pe-downlevel.py scan  "C:\Users\ye\AppData\Local\Programs\DSH Desktop"
python pe-downlevel.py patchdir "C:\Users\ye\AppData\Local\Programs\DSH Desktop" 6 1
```

**补丁后实测**：

```
ELECTRON_RUN_AS_NODE=1 "DSH Desktop.exe" --version        → v24.18.1     ✅
ELECTRON_RUN_AS_NODE=1 "DSH Desktop.exe" "<…>\desktop-cli.js" --version → 0.1.5-rc.2 ✅
GUI 启动                                                   → 5 进程存活，创建 Roaming 目录 ✅
Chromium 日志: ERROR:base\trace_event\trace_logging_minimal_win.cc:25] Provider registration failure
                                                            ← 良性，即 VxKex 接管 ETW 的表现
```

> 注意：每次 DSH Desktop 自动升级后，新 exe 的 PE 头会被重置为 10.0，**必须重新打补丁**。

---

## 三、完整链路（离线可移植）

### 3.1 网络前置

目标机系统 DNS 只有 IPv6 占位地址（`fec0:0:0:ffff::1/2/3`）→ 域名全部解析失败。
修复：DNS 指向 **192.168.17.2**（VMware NAT 的 DNS）。
出网走宿主代理 **`http://192.168.17.1:7897`**（Clash Verge / verge-mihomo，已 `0.0.0.0` 监听）。
宿主代理做 TLS 拦截，脚本需 `verify_mode=CERT_NONE`。

### 3.2 制品清单

| 制品 | 来源 | 体量 |
|---|---|---|
| Node 24.14.0 官方包 | nodejs.org/dist | 36 MB |
| VxKex-NEXT 安装器 | GitHub `YuZhouRen86/VxKex-NEXT` | 4.8 MB |
| 7zr.exe（解包用） | 7-zip.org/a/7zr.exe | 0.6 MB |
| DSH Desktop 2.0.10 安装器 | GitHub `anywhere-labs/deepseek-harness-desktop` | 148.8 MB |
| KB2670838 Platform Update | MS Update Catalog | 11.3 MB（**本机 wusa 静默无效，CBS 无记录，尚未解决**） |

### 3.3 目标机当前落地路径

```
C:\dsh\node24-off\             Node 24.14.0（已启用 VxKex）
C:\dsh\kex\                    VxKex 解包内容
C:\dsh\pkg\                    安装包仓库
C:\Program Files\VxKex\        VxKex 已安装
C:\Windows\System32\KexDll.dll
C:\Users\ye\AppData\Local\Programs\DSH Desktop\   DSH Desktop 2.0.10（8 文件已打 PE 补丁）
C:\Users\ye\.dsh\              仅 profiles（应用自动创建）
C:\Users\ye\AppData\Roaming\DSH Desktop\          应用数据（20 条目）
```

### 3.4 DSH Desktop 安装方式

electron-builder 默认**单用户安装**：
`DSH-Desktop-2.0.10-x64-Setup.exe /S` → `%LOCALAPPDATA%\Programs\DSH Desktop`（默认安装目录带空格，无需 `/D=`）。

---

## 四、当前卡点与下一步

**卡点**：应用停在首次运行流程，未监听 `43120`。因为
`%APPDATA%\DSH Desktop\profile-selection\state.json` 是出厂值 `{"version":2,"active":"desktop"}`，
而本机是 `{"version":2,"active":"code"}`。

**下一步（配置迁移阶段）**：

1. 迁移 `code` profile 定义：`package.json`、`cordis.patch.yml`、`pnpm-lock.yaml`、`pnpm-workspace.yaml`
2. 在目标机用 DSH 自带 pnpm 安装插件（12 个），或整体迁移 `node_modules`
3. 迁移 `~/.dsh` 配置：`settings.yaml`、`.agent-presets/`、`skills/`、`ctf-skills/`、`forensics-skills/`、`pentest-skills/`、`skins/`、`pets/`、`capability-panel/`、`mcp-manager.json`、`dsh-ssh.json`
4. 把 `profile-selection` 的 `active` 改为 `code`
5. 处理 MCP 工具链（目标机无 D 盘，`cordis.patch.yml` 里硬编码 `D:/CTF_TOOLS/...` 需调整或建 D 盘）
6. 面向**无外网 Win7** 打包（VxKex + Node + DSH + 插件 + 已打补丁的 Electron 全部离线化）

---

## 五、安全提醒

- `~/.dsh/profiles/code/cordis.patch.yml` 含**明文 GitHub PAT** 与 **msf 口令**；`~/.dsh/.credentials.yaml` 亦为明文。跨机复制前必须轮换。
- PE 降级补丁会**使 Electron 的数字签名失效**（不影响加载，但需知悉）。

---

## 六、工具脚本（本次产出，均在 `内网部署dsh\`）

| 脚本 | 用途 |
|---|---|
| `pe-missing.py` | 比对 PE 导入表与系统 DLL 导出表，列出 Win7 缺失符号 |
| `pe-version.py` | 打印 PE 可选头的 OS/子系统版本（加载器判定依据） |
| `pe-downlevel.py` | `scan` / `patch` / `patchdir`：把 PE 声明的 OS 版本降到 6.1 |
| `kex-coverage.py` | 检查 VxKex 扩展 DLL 是否覆盖所需符号 |
| `dl.py` | 经宿主代理下载（GitHub release / 任意 URL） |
| `kb.py` | 从 MS Update Catalog 解析并下载 Win7 补丁 |
| `get-official-node.py` | 下载解包官方 Node |
| `probe-dsh-host.ps1` | 无界面探测 DSH Desktop 是否真正启动（进程/端口/日志） |
