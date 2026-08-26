## 安装

```bash
brew install --cask waveblog/tap/aibar
```

或下载下面的 DMG。

## 关于联网

aibar 默认会查询 Claude 的实时剩余额度（只访问 `api.anthropic.com`，
读取本机 Keychain 里的登录凭据）。Codex 与 Grok 的额度本地日志里就有，不发请求。

首次启动有一页说明，「保持开启」与「切换到离线模式」两个按钮等权并列。
离线模式下除 Claude 的实时额度外，功能一个不少，随时可在菜单栏面板顶部切换。
