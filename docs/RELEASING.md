# 发布

```bash
git tag v0.5.0
git push origin v0.5.0
```

CI 会构建、打 DMG、创建 GitHub Release，并顺手生成一份填好 `sha256` 的
Homebrew Cask（`dist/aibar.rb`）。

## 签名与公证（可选）

没有配置就跳过，产出未签名包，Release 说明里会自动附上绕过 Gatekeeper 的步骤。
配置之后用户可以直接双击打开。

需要一个**付费的 Apple 开发者账号**（$99/年）和以下仓库 Secret：

| Secret | 怎么拿 |
|---|---|
| `MACOS_CERT_P12` | 钥匙串里导出 “Developer ID Application” 证书为 .p12，`base64 -i cert.p12 \| pbcopy` |
| `MACOS_CERT_PASSWORD` | 导出 .p12 时设的密码 |
| `MACOS_TEAM_ID` | [developer.apple.com](https://developer.apple.com/account) → Membership 里的 Team ID |
| `NOTARY_APPLE_ID` | 开发者账号邮箱 |
| `NOTARY_PASSWORD` | [appleid.apple.com](https://appleid.apple.com) 生成的 App 专用密码，不是登录密码 |

判断依据是 `MACOS_CERT_P12` 与 `MACOS_TEAM_ID` 都非空。缺任意一个就走未签名路径。

本地也可以单独跑：

```bash
export TEAM_ID=XXXXXXXXXX NOTARY_APPLE_ID=you@example.com NOTARY_PASSWORD=xxxx-xxxx-xxxx-xxxx
./scripts/sign-and-notarize.sh .build/manual/aibar.app
```

## Homebrew Cask（可选）

要支持 `brew install --cask waveblog/tap/aibar`，需要另建一个名为
`homebrew-tap` 的仓库，把发布时生成的 `dist/aibar.rb` 放进 `Casks/aibar.rb`。

没建之前，README 只引导用户下载 DMG。
