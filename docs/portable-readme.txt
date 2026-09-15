DSH Desktop for Windows 7 — portable build {{VERSION}}
=====================================================

这个包里有什么
--------------
  app\                 DSH Desktop 官方版，已打 PE 兼容补丁（可执行文件在 app\DSH Desktop.exe）
  vxkex\                VxKex NEXT {{VXKEX}}（Windows 7 的 API 扩展层，解包后）
  install.cmd          一键安装（右键 → 以管理员身份运行）
  install-portable.ps1 上面的实际脚本
  verify-win7.ps1      随时自检
  NOTICE.txt           上游归属与许可

安装
----
1. 解压到**路径不含中文**的目录，建议 C:\DSH-Win7
   （VxKex 会把可执行文件的绝对路径写进注册表，之后不要移动该目录）
2. 右键 install.cmd → 以管理员身份运行
3. 完成后双击桌面上的 “DSH Desktop”

要求
----
  * Windows 7 SP1 x64
  * KB2533623（DllDirectories 更新）
  * 管理员权限

为什么要这些步骤
----------------
官方 DSH Desktop 基于 Electron 43 / Chromium 140，Chromium 110 起已不再支持
Windows 7。这里做了两件事，都不需要重新编译：

  1. 可执行文件声明了 “需要 Windows 10”（PE 头 OS 版本 10.0），Windows 7 的
     加载器会直接拒绝，报「不是有效的 Win32 应用程序」。补丁把它改回 6.1。
  2. 补上 Windows 7 缺少的 13 个 API —— 由 VxKex NEXT 提供。

重要提醒
--------
* DSH Desktop **自动升级后必须重新运行 install.cmd**：新下载的可执行文件
  OS 版本会变回 10.0，又会被加载器拒绝。运行 verify-win7.ps1 可以确认。
  不想反复处理的话，请在设置里关闭自动更新。
* 打过补丁的文件**数字签名失效**（不影响运行）。
* VxKex NEXT 上游开发已暂停至 2027 年 8 月。

遇到问题
--------
先跑 verify-win7.ps1，它会指出是 PE 头、VxKex 还是运行库的问题。
细节见仓库的 docs\ 目录。
