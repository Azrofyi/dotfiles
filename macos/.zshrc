setopt hist_ignore_dups share_history append_history
export ZSH="$HOME/.oh-my-zsh"

ZSH_THEME="robbyrussell"

plugins=(
  git
  zsh-autocomplete
  zsh-autosuggestions
  fast-syntax-highlighting
)

if [ -s "$ZSH/oh-my-zsh.sh" ]; then
  source "$ZSH/oh-my-zsh.sh"
else
  echo "⚠️ Oh My Zsh not found at $ZSH"
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
