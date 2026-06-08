# Money Means — Mac dev tooling
# Usage: brew bundle --file=./Brewfile

# CLI tools
brew "git"
brew "gh"
brew "mise"          # polyglot version manager — we use it for Node (Volta is unmaintained as of 2026)
brew "azure-cli"
brew "tmux"          # session multiplexer
brew "ttyd"          # terminal-over-WebSocket (for any project that needs it)
brew "jq"            # general JSON wrangling; used by various install scripts
brew "python@3.13"   # brew default Python; projects that need ≥ 3.11 use this

# Apps
cask "iterm2"
cask "visual-studio-code"
cask "notion"
cask "slack"
cask "microsoft-teams"
cask "itsycal"
cask "rectangle"
cask "vlc"
cask "docker-desktop"  # canonical token (the old "docker" cask is a deprecated alias)
cask "devtunnel"       # Microsoft dev tunnels — useful for remote access flows

# Browsers are installed via lib/browsers.sh — interactive multi-select
# (or MAC_SETUP_BROWSERS env var) so each user can pick chrome/firefox/arc/brave.
