#!/usr/bin/env bash
set -euo pipefail

readonly BIN_DIR="$HOME/.local/bin"
readonly CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
readonly CONFIG_DIR="$CONFIG_HOME/gsr-replay"
readonly SERVICE_PATH="$CONFIG_HOME/systemd/user/gsr-replay.service"
readonly ARCHIVE_SERVICE_PATH="$CONFIG_HOME/systemd/user/gsr-replay-archive.service"
readonly ARCHIVE_TIMER_PATH="$CONFIG_HOME/systemd/user/gsr-replay-archive.timer"
readonly AUDIO_MONITOR_SERVICE_PATH="$CONFIG_HOME/systemd/user/gsr-replay-audio-monitor.service"

main() {
  local purge=false cli_help=""
  if [[ "${1:-}" == "--purge" ]]; then
    purge=true
  elif [[ $# -gt 0 ]]; then
    printf 'Usage: ./uninstall.sh [--purge]\n' >&2
    exit 1
  fi

  if [[ -x "$BIN_DIR/gsr-replay" ]]; then
    if ! "$BIN_DIR/gsr-replay" waybar-uninstall; then
      printf 'Error: Waybar cleanup failed. The CLI and service were preserved so cleanup can be retried.\n' >&2
      exit 1
    fi
    cli_help="$("$BIN_DIR/gsr-replay" help 2>/dev/null || true)"
    if [[ "$cli_help" == *hotkeys-uninstall* ]]; then
      if ! "$BIN_DIR/gsr-replay" hotkeys-uninstall; then
        printf 'Error: Hyprland hotkey cleanup failed. The CLI and service were preserved so cleanup can be retried.\n' >&2
        exit 1
      fi
    elif [[ -e "$CONFIG_DIR/hyprland.conf" || -e "$CONFIG_DIR/hyprland-install" ]]; then
      printf 'Error: Hyprland hotkeys were installed by a newer CLI and could not be removed safely.\n' >&2
      exit 1
    fi
  fi

  systemctl --user disable --now gsr-replay.service >/dev/null 2>&1 || true
  systemctl --user disable --now gsr-replay-archive.timer >/dev/null 2>&1 || true
  rm -f "$BIN_DIR/gsr-replay" "$BIN_DIR/gsr-replay-callback" "$SERVICE_PATH" "$ARCHIVE_SERVICE_PATH" "$ARCHIVE_TIMER_PATH" "$AUDIO_MONITOR_SERVICE_PATH"
  systemctl --user daemon-reload >/dev/null 2>&1 || true

  if [[ "$purge" == "true" ]]; then
    rm -rf "$CONFIG_DIR"
    printf 'Removed gsr-replay and its configuration. Replay videos were preserved.\n'
  else
    printf 'Removed gsr-replay. Configuration was preserved in %s.\n' "$CONFIG_DIR"
  fi
}

main "$@"
