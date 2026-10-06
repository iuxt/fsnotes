# FSNotes

[English](README.md)
[繁體中文](README_zh_TW.md)

FSNotes是适用于 macOS 和 iOS 的现代笔记管理器。

## macOS 应用

<a href="https://itunes.apple.com/app/fsnotes/id1277179284">
	<img src="https://fsnot.es/img/badge-download-on-the-mac-app-store.svg" alt="">
</a>

<img src="https://raw.githubusercontent.com/glushchenko/fsnotes/master/code.png" alt="macOS FSNotes" style="max-width:100%;">

### 主要功能

- **优先支持 Markdown**。也支持任何纯文本文件。
- **快速且轻量**。能够流畅处理 10k+ 个文件。
- **随时随地访问**。与 iCloud Drive 或 Dropbox 同步。
- **多文件夹**存储。
- **键盘为中心**。受 [nvalt](https://brettterpstra.com/projects/nvalt/) 启发的控件和快捷键。
- **代码块内语法高亮**。支持超过 170 种编程语言。
- **内联图片**支持。
- 使用**标签**进行组织。
- 使用 `[[双括号]]` 进行**跨笔记链接**。
- **弹性两窗格视图**。选择垂直或水平布局。
- 支持**外部编辑器**（更改会与 UI 实时同步）。
- **置顶**重要笔记。
- **快速复制笔记**到剪贴板。
- **暗黑模式**。
- **Mermaid 和 MathJax** 支持。
- 可选的**Git 版本控制**和**备份**。

---

## iOS 应用

<a href="https://itunes.apple.com/app/fsnotes-manager/id1346501102">
	<img src="https://fsnot.es/img/badge-download-on-the-app-store.svg" alt="">
</a>

<img width="300" alt="FSNotes for iOS" src="https://fsnot.es/img/fsnotes6-ios/s1x.webp?v=1.0"> <img width="300" alt="FSNotes for iOS" src="https://fsnot.es/img/fsnotes6-ios/s2x.webp?v=1.0">

### 主要功能

- 通过 iCloud Drive 进行**同步**。
- **3D Touch** 和**可配置键盘**。
- 保持与桌面应用同步的**置顶**笔记。
- **动态字体**。
- **暗黑模式**。
- **分享**扩展。
- **Git** 集成。
- **网页**创建。

## 许可证

FSNotes 使用 **Swift 5** 编写，采用 MIT 许可证开源。

## 特别鸣谢

@zcohan（https://soulver.app）提供了 Soulver 核心框架 https://github.com/soulverteam/SoulverCore，用于简单的内联计算。

### 本地构建并安装（macOS）

安装完整的 Xcode 后，在项目目录运行 `./build.sh`。脚本会构建 Release 版本，
使用本机临时签名，并安装到 `/Applications/FSNotes.app`；已有版本会自动替换。
构建或复制失败时保留旧版本，替换失败时尝试恢复旧版本。更新前会请求运行中的 FSNotes 正常退出。
首次构建需要下载依赖；日志位于 `.build/build.log`。无需 Apple 开发者证书，安装目录无写权限时会提示输入 `sudo` 密码。

### GitHub Actions 自动打包（macOS）

将包含 `.github/workflows/release.yml` 的提交推送到 GitHub 后，推送任意 tag 即可触发 Release 构建：

```bash
git tag v7.3.4
git push origin v7.3.4
```

Actions 使用 Xcode 26.2，在 Apple Silicon 的 macOS runner 上构建 ARM64 应用。
发布包要求使用 Apple Silicon 的 Mac，系统为 macOS 15 或更新版本，以覆盖内置 Git 和 Git LFS 的系统要求。
构建成功后，自动创建对应 tag 的 GitHub Release，上传
`FSNotes-<tag>-macos-arm64.zip` 及其 SHA-256 校验文件。
重跑工作流会更新同一 Release 的附件；构建失败时可在 Actions 下载构建日志。
tag 中不适合文件名的字符会替换为 `_`；`v7.3.4`、`7.3.4` 或 `v7.3.4-beta.1` 这类 tag
会将应用版本设为 `7.3.4`，构建号使用 Actions 的运行编号。
其他 tag 使用项目中配置的应用版本；带 `-` 后缀的版本 tag 会发布为预发行版。

无需额外配置 secrets，发布使用 GitHub 自动提供的 `GITHUB_TOKEN`。
下载 ZIP，解压后将 `FSNotes.app` 拖入 `/Applications` 即可运行，Git 和 Git LFS 已包含在应用中。
构建使用临时签名，未经 Apple 公证；首次打开被 macOS 拦截时，在「系统设置 → 隐私与安全」中选择「仍要打开」。

本地仅打包、不安装或启动应用，可在已安装 Xcode 和 Git LFS 的对应架构 Mac 上运行：

```bash
bash Scripts/package-release.sh v7.3.4 "$(uname -m)"
```

产物位于 `.build/release/dist/`，日志位于 `.build/release/build.log`。

### Git 历史记录与单文件恢复（macOS）

先在「偏好设置 → Git」中初始化笔记目录的 Git 仓库，使用「保存版本」或自动快照生成提交。
选中一篇笔记，在右键菜单或「文件 → 历史记录」中查看该文件的提交时间、Commit ID 和提交摘要。
选择一条历史记录，确认后即可恢复该文件；也可以选择「从指定 Commit 恢复…」，输入完整或缩写的 Commit ID。

恢复会覆盖当前文件内容，不移动分支或 HEAD，不改变暂存区，也不自动提交其他文件。
历史记录直接读取当前 HEAD 可达的提交，不依赖历史缓存；不会跨文件重命名追踪旧路径。
