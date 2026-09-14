#!/usr/bin/env bash
# os_detect.sh - operating system / architecture / package manager detection.
set -euo pipefail

# llmctl_os -> linux | macos
llmctl_os() {
  case "$(uname -s)" in
    Linux)  echo "linux" ;;
    Darwin) echo "macos" ;;
    *)      echo "unknown"; return 1 ;;
  esac
}

# llmctl_arch -> x86_64 | arm64 | ...
llmctl_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo "x86_64" ;;
    arm64|aarch64) echo "arm64" ;;
    *)             uname -m ;;
  esac
}

# Portable core count.
llmctl_nproc() {
  if [[ "$(llmctl_os)" == "macos" ]]; then
    sysctl -n hw.ncpu 2>/dev/null && return 0
  fi
  if have_cmd nproc; then
    nproc
  elif have_cmd getconf; then
    getconf _NPROCESSORS_ONLN
  else
    echo 1
  fi
}

# Best-effort package manager hint for error messages.
llmctl_pkg_hint() {
  case "$(llmctl_os)" in
    macos)
      if have_cmd brew; then echo "brew install <pkg>"; else echo "install Homebrew (https://brew.sh), then brew install <pkg>"; fi
      ;;
    linux)
      if   have_cmd apt-get; then echo "sudo apt-get install <pkg>"
      elif have_cmd dnf;     then echo "sudo dnf install <pkg>"
      elif have_cmd pacman;  then echo "sudo pacman -S <pkg>"
      elif have_cmd zypper;  then echo "sudo zypper install <pkg>"
      elif have_cmd apk;     then echo "apk add <pkg>"
      else echo "install <pkg> with your distribution package manager"
      fi
      ;;
  esac
}

# is_apple_silicon -> 0 when macOS on arm64
is_apple_silicon() {
  [[ "$(llmctl_os)" == "macos" && "$(llmctl_arch)" == "arm64" ]]
}
