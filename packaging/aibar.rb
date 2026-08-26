# Homebrew Cask。发布时由 CI 把 version / sha256 填进 waveblog/homebrew-tap。
#
#   brew install --cask waveblog/tap/aibar
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
