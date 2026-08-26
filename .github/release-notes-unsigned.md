
## 这个版本未经 Apple 签名

首次打开会被 Gatekeeper 拦下。两种方式之一：

**右键打开**：在「访达」里右键点 `aibar.app` → 打开 → 再点一次「打开」。

**命令行**：

```bash
xattr -dr com.apple.quarantine /Applications/aibar.app
```

之所以不能只靠双击：aibar 需要读取 `~/.claude`、`~/.codex`、`~/.grok`，
这些路径在 App Sandbox 里拿不到，所以走 Developer ID 分发路线。
签名与公证需要付费的 Apple 开发者账号，本版本暂未配置。

源码在这里，你也可以自己构建：`./scripts/build-app.sh`。
