# 构建环境影响与踩坑记录

> 这是为本次 cmux Composer Input 功能首次构建所做的环境配置记录，供后续接手或重新构建时参考。

## 一、为本次构建额外安装/启用的内容

| 项目 | 版本/路径 | 说明 |
|------|-----------|------|
| **Xcode** | 26.4 (Build 17E192) | 安装在 `/Applications/Xcode.app`。Command Line Tools 不够，必须装完整 Xcode（cmux 的 GhosttyKit 是 universal xcframework，含 iOS target，需要 iOS SDK） |
| **Xcode 许可** | — | `sudo xcodebuild -license accept` |
| **Metal Toolchain** | 17E188 | Xcode 26 默认不再内置，必须 `sudo xcodebuild -downloadComponent MetalToolchain`（约 700 MB DMG）。下载完通过 cryptex 自动挂在 `/var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-v17.5.188.0.*/` |
| **zig** | 0.15.2 (Homebrew) | `brew install zig` — 用于编译 ghostty submodule |
| **代理** | `127.0.0.1:7897` (HTTP/SOCKS5) | 用户提供的本地代理，用于下载 ghostty 的 zig 依赖 |

## 二、对仓库的修改（本次实现的源码改动）

只动业务源码，**未修改** ghostty/bonsplit 子模块。

```
新增
  Sources/Composer/ComposerState.swift
  Sources/Composer/ComposerInputView.swift
  agentcontext/                     ← 本目录

修改
  GhosttyTabs.xcodeproj/project.pbxproj      ← 注册新文件
  Resources/Localizable.xcstrings            ← composer.placeholder + shortcut.toggleComposer.label
  Sources/AppDelegate.swift                  ← 处理 toggleComposer 快捷键
  Sources/GhosttyTerminalView.swift          ← Composer overlay 挂载 + 焦点保护
  Sources/KeyboardShortcutSettings.swift     ← 注册 toggleComposer Action
  Sources/Panels/TerminalPanel.swift         ← composerState + 草稿持久化 + send/dismiss
  Sources/Panels/TerminalPanelView.swift     ← 把 composerState 透传给 GhosttyTerminalView
  Sources/TabManager.swift                   ← toggleComposer() + 通知监听
```

## 三、构建期间用到的临时基础设施（**用户机器上仍在跑/留有文件**）

> **重要**：以下都是为绕过 zig 不读 HTTP 代理 + Xcode 26 缺 Metal Toolchain 而临时搭的本地服务，**不要直接删，rebuild 还要用**。

### 1. 本地依赖镜像（HTTP 文件服务器）
- 端口：`127.0.0.1:18976`
- 服务文件：`/tmp/zig-deps-mirror/`（37 个 tarball，约 30 MB）
- 服务进程：`python3 /tmp/zig-mirror-server.py`，PID 在 `/tmp/zig-mirror.pid`
- 它把 `https://deps.files.ghostty.org/...` 和 `github.com/...archive/...tar.gz` 重写为本地服务

### 2. Git Smart HTTP 服务器（处理 `git+http://` URL）
- 端口：`127.0.0.1:19418`
- 仓库根：`/tmp/zig-git-server/jacobsandlund/uucode.git`（vaxis 依赖 uucode 用的是 `git+https://`）
- 服务进程：`python3 /tmp/zig-git-http-server.py`，PID 在 `/tmp/zig-git-http.pid`
- 内部用 Xcode 自带的 `git-http-backend` 做 CGI

### 3. 预放进 zig 全局 cache 的包
- `~/.cache/zig/p/uucode-0.1.0-ZZjBPj96QADXyt5sqwBJUnhaDYs_qBeeKijZvlRa0eqM/`
- 这是 vaxis 用的 uucode 0.1.0 commit 5f05f8f8…，因为 zig 的 git client 无法跟我们的 git http server 协商 capability，所以直接预放 cache 跳过 fetch

### 4. 启动脚本（重启服务用）
```bash
# 启动 mirror
python3 /tmp/zig-mirror-server.py > /tmp/zig-mirror.log 2>&1 &
echo $! > /tmp/zig-mirror.pid

# 启动 git http
python3 /tmp/zig-git-http-server.py > /tmp/zig-git-http.log 2>&1 &
echo $! > /tmp/zig-git-http.pid
```

## 四、踩过的坑（按时间顺序）

### 1. zig 下载依赖 400 Bad Request
- 现象：`./scripts/setup.sh` → `bad HTTP response code: '400 Bad Request'` 拉 `deps.files.ghostty.org/uucode-...`
- 原因：网络环境拒绝直连 ghostty deps CDN
- 失败尝试：
  - 设 `https_proxy/http_proxy/all_proxy` 环境变量 — **zig 0.15 不读这些环境变量**
  - 大写的 `HTTP_PROXY` / `HTTPS_PROXY` — 同样不读
  - `zig fetch file://...` — segfault (exit 139)
- 最终方案：把所有 `build.zig.zon` 里的 `https://deps.files.ghostty.org/` 改写成 `http://127.0.0.1:18976/`，配本地 mirror

### 2. zig package cache 目录嵌套问题
- 现象：手动把 tarball 解压到 `~/.cache/zig/p/$HASH/` 后，build 报 `does not have a build.zig`
- 原因：tarball 解出来是 `zig-wayland/build.zig`，cache 里多了一层目录嵌套
- 教训：zig 期望 `$HASH/build.zig`，不是 `$HASH/<single-subdir>/build.zig`
- 真正解决：放弃手动塞 cache，改用本地 HTTP mirror 让 zig 自己下载 + 自己解压

### 3. Tarball 的 `.tgz` 后缀触发 TarHeader 错误
- 现象：`ghostty-themes-...tgz` 报 `error: unable to unpack tarball to temporary directory: TarHeader`
- 原因：`python3 -m http.server` 默认按 `Content-Type: text/plain` 发送 `.tgz`，zig 解压器对此报错
- 解决：写一个自定义的 `zig-mirror-server.py`，按后缀返回正确的 Content-Type（`application/gzip`、`application/zstd`、`application/x-xz`）

### 4. 传递依赖 (zlib, libxml2, ...) 仍然走真实 ghostty CDN
- 现象：第二次 build 卡在 `dependency 'zlib' does not have a build.zig`
- 原因：除了顶层 `ghostty/build.zig.zon`，还有 `ghostty/pkg/*/build.zig.zon`、`example/*/build.zig.zon` 共 38 个 zon 文件，全部要批量改写
- 解决：递归 `find . -name "build.zig.zon"` 全部 sed 改写

### 5. zig 下载完 vaxis 后又出 GitHub URL
- 现象：`vaxis-.../build.zig.zon` 里还有 `git+https://github.com/jacobsandlund/uucode#...` 和 `https://github.com/...archive/...tar.gz`
- 原因：zig 把 vaxis 解压到 `~/.cache/zig/p/vaxis-.../` 后，再读它内部的 `build.zig.zon`，里面又有外部 URL
- 解决：循环 build → patch 新出现的 cache zon → build，直到稳定

### 6. `git+git://` 不被 zig 支持
- 把 `git+https://github.com/jacobsandlund/uucode` 改成 `git+git://127.0.0.1/...` 想用 git daemon
- zig 报 `unsupported URL scheme: git+git`
- 改成 `git+http://127.0.0.1:19418/...` + `.git` 后缀
- 用 `git-http-backend`（CGI）+ Python HTTP server 做 smart HTTP 协议

### 7. 仍然 `unable to discover remote git server capabilities: UnsupportedProtocol`
- zig 0.15 的 git client 跟我们这个 backend 协商失败（具体什么不兼容没深究）
- 终极方案：直接把 uucode @ 5f05f8f… 的源码 git clone 出来扔到 `~/.cache/zig/p/uucode-0.1.0-ZZjBPj96QADXyt5sqwBJUnhaDYs_qBeeKijZvlRa0eqM/`，zig 一看 cache 命中就跳过 fetch

### 8. Xcode 26 缺 Metal Toolchain
- 现象：build 阶段 `error: cannot execute tool 'metal' due to missing Metal Toolchain`
- 解决：`sudo xcodebuild -downloadComponent MetalToolchain`（用户操作）

### 9. 下载完 Metal Toolchain 但 `metal --version` 仍报错
- 现象：DMG 已下载到 `/System/Library/AssetsV2/com_apple_MobileAsset_MetalToolchain/.../022-19852-235.dmg` 但 `xcodebuild -importComponent` 报 invalid contents
- 原因：DMG 版本是 17E188，Xcode 是 17E192，差一点。但 cryptex 已经自动挂上去了
- 验证：`xcrun --find metal` → `/var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-v17.5.188.0.*/Metal.xctoolchain/usr/bin/metal` 存在且可用
- 我之前用 `hdiutil attach` 手动挂了一份 `MetalToolchainCryptex` 卷，挡住了系统的 cryptex。`hdiutil detach` 卸掉后就好了

### 10. App 启动后 composer 输入框抢不住焦点（业务 bug）
- 现象：⌘⇧I 召唤出 composer，但打字时字符在 composer 和终端之间来回跳
- 根因：cmux 的 terminal 有非常激进的焦点回收链路（`ensureFocus()` / `applyFirstResponderIfNeeded()` / `reassertTerminalSurfaceFocus()`），search overlay 已经处理过这种情况，composer 没处理
- 修复：mirror search overlay 的整套模式 — `restoreComposerFocus`、`isComposerOverlayOrDescendant`、cross-surface 守卫、text view 用 `becomeFirstResponder` 回调 `terminalSurface.setFocus(false)` 关掉光标闪烁循环
- 详见 `02-composer-feature.md`

## 五、清理本次构建（如果想恢复干净环境）

```bash
# 杀掉本地服务
kill $(cat /tmp/zig-mirror.pid 2>/dev/null) 2>/dev/null
kill $(cat /tmp/zig-git-http.pid 2>/dev/null) 2>/dev/null

# 删临时文件
rm -rf /tmp/zig-deps-mirror /tmp/zig-git-server
rm -f /tmp/zig-mirror-server.py /tmp/zig-git-http-server.py
rm -f /tmp/zig-mirror.pid /tmp/zig-git-http.pid /tmp/zig-mirror.log /tmp/zig-git-http.log

# 清 zig cache（重新下载就回到原始 ghostty CDN 路径）
rm -rf ~/.cache/zig/p

# 还原 ghostty 子模块（所有 build.zig.zon 都被 sed 改了）
cd /Users/ansonlo/project/cmux/ghostty
git checkout -- '*.zon'
find pkg example -name 'build.zig.zon.bak' -delete 2>/dev/null
find . -name 'build.zig.zon.bak' -delete 2>/dev/null

# 清这次的 cmux build artifact
rm -rf "/Users/ansonlo/Library/Developer/Xcode/DerivedData/cmux-composer"
rm -rf "/tmp/cmux-composer" "/tmp/cmux-debug-composer.sock" "/tmp/cmux-debug-composer.log"
```

## 六、再次 rebuild 的最短路径

如果上述临时设施（mirror 服务 + zig cache + 改过的 build.zig.zon）都还在：

```bash
cd /Users/ansonlo/project/cmux

# 启服务（如果没在跑）
pgrep -f zig-mirror-server.py >/dev/null || python3 /tmp/zig-mirror-server.py >/tmp/zig-mirror.log 2>&1 &
pgrep -f zig-git-http-server.py >/dev/null || python3 /tmp/zig-git-http-server.py >/tmp/zig-git-http.log 2>&1 &

# 改源码后直接 reload
./scripts/reload.sh --tag composer --launch
```

如果是干净环境（无任何临时设施），需要照"二、三"重新搭建。
