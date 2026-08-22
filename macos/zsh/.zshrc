# -----------------------------------------------------------------------------
# Oh My Zsh
# -----------------------------------------------------------------------------

export ZSH="$HOME/.oh-my-zsh"

ZSH_THEME="robbyrussell"

if (($+commands[fzf])); then
	source <(fzf --zsh)
else
	echo "⚠️ fzf not found — skipping fzf key bindings"
fi

plugins=(
  git
  fzf-tab
  fast-syntax-highlighting
  zsh-autosuggestions
)

if [[ -s "$ZSH/oh-my-zsh.sh" ]]; then
  source "$ZSH/oh-my-zsh.sh"
else
  print -u2 "Oh My Zsh not found at $ZSH"
fi

# -----------------------------------------------------------------------------
# Aliases
# -----------------------------------------------------------------------------

# Navigation
alias home='cd ~'
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'

# Shell
alias reload='exec zsh'
alias c='clear'
alias e='exit'
alias x='exit'

# System
alias lsports='sudo lsof -iTCP -sTCP:LISTEN -n -P'

# -----------------------------------------------------------------------------
# Functions
# -----------------------------------------------------------------------------

# Flush macOS DNS cache.
flushdns() {
  sudo dscacheutil -flushcache
  sudo killall -HUP mDNSResponder
}
