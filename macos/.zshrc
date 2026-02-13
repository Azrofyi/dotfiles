setopt hist_ignore_dups share_history append_history
export ZSH="$HOME/.oh-my-zsh"

ZSH_THEME="robbyrussell"

plugins=(
  git
  fzf-tab
  fast-syntax-highlighting
  zsh-autosuggestions
)

if [ -s "$ZSH/oh-my-zsh.sh" ]; then
  source "$ZSH/oh-my-zsh.sh"
else
  echo "⚠️ Oh My Zsh not found at $ZSH"
fi

if (( $+commands[fzf] )); then
  source <(fzf --zsh)
else
  echo "⚠️ fzf not found — skipping fzf key bindings"
fi

# Aliases for common dirs
alias home="cd ~"
alias ..="cd .."
alias ...="cd ../.."
alias ....="cd ../../.."

# System Aliases
alias reload="source ~/.zshrc && echo 'Reloaded ~/.zshrc ✅'"
alias c="clear"
alias e="exit"
alias x="exit"

alias lsports="sudo lsof -iTCP -sTCP:LISTEN -n -P"

# macOS DNS flush
flush() {
    sudo dscacheutil -flushcache
    sudo killall -HUP mDNSResponder
}
