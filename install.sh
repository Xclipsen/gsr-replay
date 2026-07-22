#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT_DIR
readonly BIN_DIR="$HOME/.local/bin"
readonly CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
readonly SERVICE_DIR="$CONFIG_HOME/systemd/user"
readonly SERVICE_PATH="$SERVICE_DIR/gsr-replay.service"

main() {
  local run_setup=true
  if [[ "${1:-}" == "--no-setup" ]]; then
    run_setup=false
  elif [[ $# -gt 0 ]]; then
    printf 'Usage: ./install.sh [--no-setup]\n' >&2
    exit 1
  fi

  require_command install
  require_command systemctl
  mkdir -p "$BIN_DIR" "$SERVICE_DIR"

  backup_if_different "$ROOT_DIR/bin/gsr-replay" "$BIN_DIR/gsr-replay"
  backup_if_different "$ROOT_DIR/bin/gsr-replay-callback" "$BIN_DIR/gsr-replay-callback"
  backup_if_different "$ROOT_DIR/systemd/gsr-replay.service" "$SERVICE_PATH"

  install -m 0755 "$ROOT_DIR/bin/gsr-replay" "$BIN_DIR/gsr-replay"
  install -m 0755 "$ROOT_DIR/bin/gsr-replay-callback" "$BIN_DIR/gsr-replay-callback"
  install -m 0644 "$ROOT_DIR/systemd/gsr-replay.service" "$SERVICE_PATH"
  systemctl --user daemon-reload

  printf 'Installed gsr-replay in %s.\n' "$BIN_DIR"
  if [[ "$run_setup" == "true" && -t 0 && -t 1 ]]; then
    "$BIN_DIR/gsr-replay" setup
  else
    printf 'Run "%s/gsr-replay setup" to complete onboarding.\n' "$BIN_DIR"
  fi
}

backup_if_different() {
  local source="$1" destination="$2" backup
  [[ -e "$destination" ]] || return 0
  cmp -s "$source" "$destination" && return 0
  backup="$(mktemp "$destination.backup.XXXXXX")"
  rm -f "$backup"
  cp -a "$destination" "$backup"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Error: required command is missing: %s\n' "$1" >&2
    exit 1
  }
}

main "$@"
