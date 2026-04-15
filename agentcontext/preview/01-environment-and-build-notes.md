# 01 - 构建环境与基础设施

> 对应原文：`agentcontext/01-environment-and-build-notes.md`

## 需求

为 cmux Composer Input 功能首次构建项目，需要从零搭建一套能跑通 ghostty + Xcode 26.4 + zig 的本地构建环境，并把所有临时基础设施记录下来供后续 rebuild 复用或干净恢复。

## 技术方案

| 项目 | 用途 |
|------|------|
| Xcode 26.4 (17E192) 完整安装 | GhosttyKit 是 universal xcframework 含 iOS target，需要完整 SDK，Command Line Tools 不够 |
| Metal Toolchain 17E188 | Xcode 26 默认不再内置，需要 `sudo xcodebuild -downloadComponent MetalToolchain` |
| zig 0.15.2 (Homebrew) | 编译 ghostty submodule |
| 本地 HTTP mirror 服务 (127.0.0.1:18976) | 重写 `https://deps.files.ghostty.org/...` 到本地，绕过 zig 不读 HTTP_PROXY 的限制 |
| Git Smart HTTP 服务 (127.0.0.1:19418) | 处理 vaxis 依赖的 `git+http://` URL，用 git-http-backend CGI |
| 预放 uucode 0.1.0 到 zig cache | 因为 zig 0.15 git client 跟 backend 协商失败，直接命中 cache 跳过 fetch |

源码改动只动业务源码，不动 ghostty/bonsplit 子模块——新增 `Sources/Composer/{ComposerState,ComposerInputView}.swift`，修改 8 个文件（pbxproj、Localizable、AppDelegate、GhosttyTerminalView、KeyboardShortcutSettings、TerminalPanel、TerminalPanelView、TabManager）。

## 实际执行

依次踩了 10 个坑：（1）zig 不读 `https_proxy/HTTP_PROXY` 任何环境变量；（2）手动塞 cache 时目录嵌套导致 `does not have a build.zig`；（3）`python3 -m http.server` 默认 Content-Type 让 `.tgz` 触发 TarHeader 错误；（4）传递依赖也走真实 CDN，38 个 zon 文件全要批量 sed；（5）vaxis 内部 zon 又有外部 URL 需循环 build→patch；（6）`git+git://` 不被支持；（7）git protocol 协商失败只能预放 cache；（8）Metal Toolchain 缺失；（9）`hdiutil attach` 手动挂的 cryptex 挡住系统自动挂载需要 detach；（10）业务 bug——composer 焦点被终端的 ensureFocus/applyFirstResponderIfNeeded/reassertTerminalSurfaceFocus 链路抢走。

文档同时给出干净恢复脚本（kill mirror 服务、删 `/tmp/zig-*`、`rm -rf ~/.cache/zig/p`、`git checkout -- '*.zon'`）和最短 rebuild 路径（保留临时设施时只需启服务 + `./scripts/reload.sh --tag composer --launch`）。
