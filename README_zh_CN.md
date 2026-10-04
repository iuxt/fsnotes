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
- AES-256 **加密**。
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
- **TextBundle** 和 **EncryptedTextBundle** 容器。
- 保持与桌面应用同步的**置顶**笔记。
- **动态字体**。
- **暗黑模式**。
- **分享**扩展。
- **加密笔记**支持。
- **加密文件夹**支持。
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

### Git 历史记录与单文件恢复（macOS）

先在「偏好设置 → Git」中初始化笔记目录的 Git 仓库，使用「保存版本」或自动快照生成提交。
选中一篇笔记，在右键菜单或「文件 → 历史记录」中查看该文件的提交时间、Commit ID 和提交摘要。
选择一条历史记录，确认后即可恢复该文件；也可以选择「从指定 Commit 恢复…」，输入完整或缩写的 Commit ID。

恢复会覆盖当前文件内容，不移动分支或 HEAD，不改变暂存区，也不自动提交其他文件。
TextBundle 仅恢复正文文件，保留附件。未提交的正文修改会被覆盖，请按需先保存版本。
历史记录直接读取当前 HEAD 可达的提交，不依赖历史缓存；不会跨文件重命名追踪旧路径。
