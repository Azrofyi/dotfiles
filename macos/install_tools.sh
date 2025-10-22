#!/usr/bin/env bash
set -e

GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RESET="\033[0m"

confirm() {
  read -r -p "$(echo -e "${YELLOW}$1 [y/N]: ${RESET}")" response
  [[ "$response" =~ ^[Yy]$ ]]
}

install_xcode() {
  if ! xcode-select -p &>/dev/null; then
    echo -e "${YELLOW}Xcode Command Line Tools not found. Installing...${RESET}"
    xcode-select --install &>/dev/null || true

    echo "Waiting for Xcode CLI Tools to finish installing..."
    until xcode-select -p &>/dev/null; do
      sleep 10
      echo "Still waiting..."
    done

    echo -e "${GREEN}Xcode Command Line Tools installed!${RESET}"
  else
    echo -e "${GREEN}Xcode Command Line Tools already installed.${RESET}"
  fi
}

install_rosetta() {
  if ! pkgutil --pkg-info=com.apple.pkg.RosettaUpdateAuto >/dev/null 2>&1; then
    echo -e "${YELLOW}Installing Rosetta 2...${RESET}"
    /usr/sbin/softwareupdate --install-rosetta --agree-to-license
  else
    echo -e "${GREEN}Rosetta 2 already installed.${RESET}"
  fi
}

install_omz() {
  if ! command -v omz >/dev/null 2>&1; then
    echo -e "${YELLOW}Installing Oh My Zsh...${RESET}"
    /bin/sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
  else
    echo -e "${GREEN}Oh My Zsh already installed.${RESET}"
  fi
}


install_brew() {
  if ! command -v brew >/dev/null 2>&1; then
    echo -e "${YELLOW}Installing Homebrew...${RESET}"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zprofile"
    eval "$(/opt/homebrew/bin/brew shellenv)"
  else
    echo -e "${GREEN}Homebrew already installed.${RESET}"
  fi

  brew analytics off
  brew update
}

install_zsh_plugins() {
  echo -e "${YELLOW}Installing Zsh plugins...${RESET}"
  local custom_dir="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins"

  mkdir -p "$custom_dir"

  git clone https://github.com/zsh-users/zsh-autosuggestions "$custom_dir/zsh-autosuggestions" || true
  git clone https://github.com/zdharma-continuum/fast-syntax-highlighting.git "$custom_dir/fast-syntax-highlighting" || true
  git clone https://github.com/Aloxaf/fzf-tab "$custom_dir/fzf-tab" || true

  echo -e "${GREEN}Zsh plugins installed.${RESET}"
}

echo -e "${GREEN}Setting up Mac...${RESET}"

confirm "Install Xcode Command Line Tools?" && install_xcode
confirm "Install Rosetta 2?" && install_rosetta
confirm "Install Oh My Zsh?" && install_omz
confirm "Install Homebrew?" && install_brew
confirm "Install Zsh plugins?" && install_zsh_plugins

echo -e "${GREEN}Setup complete.${RESET}"
