# Homebrew Cask 模板。
#
# 目前**还没有** tap 仓库，所以 brew 安装方式尚未可用 ——
# README 与 Release 说明里都不要提它，免得给用户一条跑不通的命令。
#
# 启用步骤见 docs/RELEASING.md：建一个名为 homebrew-tap 的仓库，
# 把发布时生成的 dist/aibar.rb 放进 Casks/。
cask "aibar" do
  version "0.5.0"
  sha256 "REPLACE_WITH_DMG_SHA256"

  url "https://github.com/waveblog/aibar/releases/download/v#{version}/aibar-v#{version}.dmg"
  name "aibar"
  desc "Menu bar usage stats for Claude Code, Codex and Grok"
  homepage "https://github.com/waveblog/aibar"

  depends_on macos: ">= :sonoma"

  app "aibar.app"

  zap trash: [
    "~/Library/Application Support/aibar",
    "~/Library/Preferences/dev.aibar.app.plist",
  ]

  caveats <<~EOS
    aibar reads usage from your local CLI logs (~/.claude, ~/.codex, ~/.grok)
    and, unless you switch it off, queries api.anthropic.com for your live
    Claude quota. The first launch explains exactly what it reads and where it
    sends it, with "keep it on" and "switch to offline mode" as equal choices.
  EOS
end
