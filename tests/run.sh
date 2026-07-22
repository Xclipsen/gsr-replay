#!/usr/bin/env bash
set -uo pipefail

LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
CLI="$ROOT_DIR/bin/gsr-replay"
CALLBACK="$ROOT_DIR/bin/gsr-replay-callback"
INSTALLER="$ROOT_DIR/install.sh"
BASH_BIN="$(command -v bash)"
ORIGINAL_PATH="${PATH:-/usr/bin:/bin}"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gsr-replay-tests.XXXXXX")"

readonly SCRIPT_DIR ROOT_DIR CLI CALLBACK INSTALLER BASH_BIN ORIGINAL_PATH TMP_ROOT

CASE_DIR=
FAKE_BIN=
CAPTURE_OUTPUT=
CAPTURE_STATUS=0
OCCURRENCES=0
JSON_REST=
TEST_NUMBER=0
PASSED=0
FAILED=0

cleanup() {
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  printf '    %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected="$1" actual="$2" message="$3"
  if [[ "$actual" != "$expected" ]]; then
    printf '    %s\n' "$message" >&2
    printf '      expected: %q\n' "$expected" >&2
    printf '      actual:   %q\n' "$actual" >&2
    exit 1
  fi
}

assert_contains() {
  local text="$1" expected="$2" message="$3"
  [[ "$text" == *"$expected"* ]] || fail "$message (missing: $expected)"
}

assert_not_contains() {
  local text="$1" unexpected="$2" message="$3"
  [[ "$text" != *"$unexpected"* ]] || fail "$message (found: $unexpected)"
}

assert_file_contains() {
  local path="$1" expected="$2" message="$3" content
  [[ -f "$path" ]] || fail "$message (file does not exist: $path)"
  content="$(<"$path")"
  assert_contains "$content" "$expected" "$message"
}

assert_files_equal() {
  local expected_path="$1" actual_path="$2" message="$3"
  [[ -f "$expected_path" ]] || fail "$message (file does not exist: $expected_path)"
  [[ -f "$actual_path" ]] || fail "$message (file does not exist: $actual_path)"
  cmp -s "$expected_path" "$actual_path" || fail "$message"
}

count_occurrences() {
  local text="$1" needle="$2" count=0
  [[ -n "$needle" ]] || fail "count_occurrences requires a non-empty needle"
  while [[ "$text" == *"$needle"* ]]; do
    text="${text#*"$needle"}"
    ((count += 1))
  done
  OCCURRENCES="$count"
}

run_capture() {
  local output_file="$CASE_DIR/captured-output"
  "$@" >"$output_file" 2>&1
  CAPTURE_STATUS=$?
  CAPTURE_OUTPUT="$(<"$output_file")"
}

setup_case() {
  CASE_DIR="$(mktemp -d "$TMP_ROOT/case.XXXXXX")" || fail "could not create test directory"
  HOME="$CASE_DIR/home"
  XDG_CONFIG_HOME="$CASE_DIR/xdg-config"
  FAKE_BIN="$CASE_DIR/fake-bin"
  PATH="$FAKE_BIN:$ORIGINAL_PATH"
  mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$FAKE_BIN" || fail "could not initialize test directory"
  cat >"$FAKE_BIN/omarchy" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$FAKE_BIN/omarchy" || fail "could not create fake omarchy"
  cat >"$FAKE_BIN/omarchy-restart-waybar" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$FAKE_BIN/omarchy-restart-waybar" || fail "could not create fake Waybar restart helper"
  export HOME XDG_CONFIG_HOME PATH
  unset FAKE_GSR_LOG FAKE_NOTIFY_LOG FAKE_SYSTEMCTL_LOG FAKE_SYSTEMCTL_STATE FAKE_SYSTEMCTL_FRAGMENT FAKE_SYSTEMCTL_DROPINS
}

make_fake_systemctl() {
  cat >"$FAKE_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
set -u

if [[ -n "${FAKE_SYSTEMCTL_LOG:-}" ]]; then
  printf '%s\n' "$*" >>"$FAKE_SYSTEMCTL_LOG"
fi

if [[ "$*" == "--user is-active --quiet gsr-replay.service" ]]; then
  [[ "${FAKE_SYSTEMCTL_STATE:-inactive}" == "active" ]]
  exit
fi
if [[ "$*" == "--user is-failed --quiet gsr-replay.service" ]]; then
  [[ "${FAKE_SYSTEMCTL_STATE:-inactive}" == "failed" ]]
  exit
fi
if [[ "$*" == "--user show gsr-replay.service --property=FragmentPath --value" ]]; then
  printf '%s\n' "${FAKE_SYSTEMCTL_FRAGMENT:-}"
  exit 0
fi
if [[ "$*" == "--user show gsr-replay.service --property=DropInPaths --value" ]]; then
  printf '%s\n' "${FAKE_SYSTEMCTL_DROPINS:-}"
  exit 0
fi
exit 0
EOF
  chmod +x "$FAKE_BIN/systemctl" || fail "could not create fake systemctl"
}

make_fake_notify_send() {
  cat >"$FAKE_BIN/notify-send" <<'EOF'
#!/usr/bin/env bash
set -u
printf '<%s>\n' "$@" >>"${FAKE_NOTIFY_LOG:?}"
EOF
  chmod +x "$FAKE_BIN/notify-send" || fail "could not create fake notify-send"
}

make_fake_findmnt() {
  cat >"$FAKE_BIN/findmnt" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_FINDMNT_UUID:-}"
EOF
  chmod +x "$FAKE_BIN/findmnt" || fail "could not create fake findmnt"
}

make_fake_recorder() {
  cat >"$FAKE_BIN/gpu-screen-recorder" <<'EOF'
#!/usr/bin/env bash
set -u
printf '<%s>\n' "$@" >"${FAKE_GSR_LOG:?}"
EOF
  chmod +x "$FAKE_BIN/gpu-screen-recorder" || fail "could not create fake recorder"
}

install_expected_service() {
  local service_path="$XDG_CONFIG_HOME/systemd/user/gsr-replay.service"
  mkdir -p "$(dirname -- "$service_path")"
  cp "$ROOT_DIR/systemd/gsr-replay.service" "$service_path"
  FAKE_SYSTEMCTL_FRAGMENT="$service_path"
  export FAKE_SYSTEMCTL_FRAGMENT
}

make_fake_omarchy() {
  cat >"$FAKE_BIN/omarchy" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$FAKE_BIN/omarchy" || fail "could not create fake omarchy"
}

write_test_config() {
  local monitor="${1:-screen}"
  local seconds="${2:-120}"
  local audio="${3:-default_output}"
  local notifications="${4:-true}"
  local output_dir="${5:-$CASE_DIR/replays}"
  local storage="${6:-disk}"
  local bitrate="${7:-12345}"
  local required_uuid="${8:-}"
  local config_dir="$XDG_CONFIG_HOME/gsr-replay"

  mkdir -p "$config_dir" || fail "could not create configuration directory"
  {
    printf 'GSR_REPLAY_MONITOR=%s\n' "$monitor"
    printf 'GSR_REPLAY_RESOLUTION=%s\n' '1280x720'
    printf 'GSR_REPLAY_FPS=%s\n' '60'
    printf 'GSR_REPLAY_SECONDS=%s\n' "$seconds"
    printf 'GSR_REPLAY_AUDIO=%s\n' "$audio"
    printf 'GSR_REPLAY_BITRATE=%s\n' "$bitrate"
    printf 'GSR_REPLAY_CODEC=%s\n' 'h264'
    printf 'GSR_REPLAY_STORAGE=%s\n' "$storage"
    printf 'GSR_REPLAY_DIR=%s\n' "$output_dir"
    printf 'GSR_REPLAY_REQUIRED_FS_UUID=%s\n' "$required_uuid"
    printf 'GSR_REPLAY_NOTIFICATIONS=%s\n' "$notifications"
    printf 'GSR_REPLAY_WAYBAR_CONFIG=%s\n' ''
    printf 'GSR_REPLAY_WAYBAR_STYLE=%s\n' ''
    printf 'GSR_REPLAY_WAYBAR_POSITION=%s\n' 'right'
    printf 'GSR_REPLAY_WAYBAR_ENABLED=%s\n' 'false'
  } >"$config_dir/config"
}

json_consume_literal() {
  local literal="$1"
  [[ "${JSON_REST:0:${#literal}}" == "$literal" ]] || fail "Waybar output is not valid JSON near: $JSON_REST"
  JSON_REST="${JSON_REST:${#literal}}"
}

json_consume_string() {
  local character escape hex code
  [[ "${JSON_REST:0:1}" == '"' ]] || fail "Waybar JSON value is not a string near: $JSON_REST"
  JSON_REST="${JSON_REST:1}"

  while ((${#JSON_REST} > 0)); do
    character="${JSON_REST:0:1}"
    JSON_REST="${JSON_REST:1}"
    case "$character" in
      '"') return 0 ;;
      \\)
        ((${#JSON_REST} > 0)) || fail "Waybar JSON ends with an incomplete escape"
        escape="${JSON_REST:0:1}"
        JSON_REST="${JSON_REST:1}"
        case "$escape" in
          '"' | \\ | / | b | f | n | r | t) ;;
          u)
            ((${#JSON_REST} >= 4)) || fail "Waybar JSON has an incomplete Unicode escape"
            hex="${JSON_REST:0:4}"
            [[ "$hex" =~ ^[[:xdigit:]]{4}$ ]] || fail "Waybar JSON has an invalid Unicode escape: $hex"
            JSON_REST="${JSON_REST:4}"
            ;;
          *) fail "Waybar JSON has an invalid escape: \\$escape" ;;
        esac
        ;;
      *)
        printf -v code '%d' "'$character"
        ((code >= 32)) || fail "Waybar JSON contains an unescaped control character"
        ;;
    esac
  done
  fail "Waybar JSON contains an unterminated string"
}

assert_waybar_json() {
  JSON_REST="$1"
  json_consume_literal '{"text":'
  json_consume_string
  json_consume_literal ',"alt":'
  json_consume_string
  json_consume_literal ',"tooltip":'
  json_consume_string
  json_consume_literal ',"class":'
  json_consume_string
  json_consume_literal '}'
  [[ -z "$JSON_REST" ]] || fail "Waybar JSON has trailing content: $JSON_REST"
}

test_help_and_version() {
  local argument
  for argument in '' help --help -h; do
    if [[ -n "$argument" ]]; then
      run_capture "$BASH_BIN" "$CLI" "$argument"
    else
      run_capture "$BASH_BIN" "$CLI"
    fi
    assert_eq 0 "$CAPTURE_STATUS" "help invocation failed for '${argument:-no argument}'"
    assert_contains "$CAPTURE_OUTPUT" 'GSR Replay - instant replay management' "help heading is missing"
    assert_contains "$CAPTURE_OUTPUT" 'Usage: gsr-replay <command>' "help usage is missing"
    assert_contains "$CAPTURE_OUTPUT" 'waybar-install' "help omits Waybar commands"
  done

  for argument in version --version -v; do
    run_capture "$BASH_BIN" "$CLI" "$argument"
    assert_eq 0 "$CAPTURE_STATUS" "version invocation failed for '$argument'"
    assert_eq 'gsr-replay 1.1.0' "$CAPTURE_OUTPUT" "version output is incorrect for '$argument'"
  done
}

test_recorder_arguments() {
  local recorder_log="$CASE_DIR/recorder-arguments"
  local output_dir="$CASE_DIR/replays with spaces"
  local callback_path="$HOME/.local/bin/gsr-replay-callback"
  local expected actual

  FAKE_GSR_LOG="$recorder_log"
  export FAKE_GSR_LOG
  make_fake_recorder
  mkdir -p "$(dirname -- "$callback_path")" || fail "could not create callback directory"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$callback_path"
  chmod +x "$callback_path"
  write_test_config 'DP-1' 75 'alsa_output.test sink' true "$output_dir"

  run_capture "$BASH_BIN" "$CLI" run
  assert_eq 0 "$CAPTURE_STATUS" "recorder command failed: $CAPTURE_OUTPUT"
  actual="$(<"$recorder_log")"
  expected="$(printf '<%s>\n' \
    -w 'DP-1' \
    -s '1280x720' \
    -f '60' \
    -c mp4 \
    -r '75' \
    -replay-storage disk \
    -bm cbr \
    -q '12345' \
    -k h264 \
    -fm cfr \
    -fallback-cpu-encoding yes \
    -sc "$callback_path" \
    -o "$output_dir" \
    -a 'alsa_output.test sink')"
  assert_eq "$expected" "$actual" "recorder arguments or argument boundaries are incorrect"
  [[ -d "$output_dir" ]] || fail "recorder output directory was not created"

  write_test_config 'DP-1' 75 none true "$output_dir"
  run_capture "$BASH_BIN" "$CLI" run
  assert_eq 0 "$CAPTURE_STATUS" "recorder command with audio disabled failed: $CAPTURE_OUTPUT"
  actual="$(<"$recorder_log")"
  expected="$(printf '<%s>\n' \
    -w 'DP-1' \
    -s '1280x720' \
    -f '60' \
    -c mp4 \
    -r '75' \
    -replay-storage disk \
    -bm cbr \
    -q '12345' \
    -k h264 \
    -fm cfr \
    -fallback-cpu-encoding yes \
    -sc "$callback_path" \
    -o "$output_dir")"
  assert_eq "$expected" "$actual" "recorder should omit -a when audio is disabled"
}

test_portal_recorder_arguments() {
  local recorder_log="$CASE_DIR/recorder-arguments"
  local output_dir="$CASE_DIR/portal-replays"
  local callback_path="$HOME/.local/bin/gsr-replay-callback"
  local expected actual

  FAKE_GSR_LOG="$recorder_log"
  export FAKE_GSR_LOG
  make_fake_recorder
  mkdir -p "$(dirname -- "$callback_path")" || fail "could not create callback directory"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$callback_path"
  chmod +x "$callback_path"
  write_test_config portal 75 default_output true "$output_dir"

  run_capture "$BASH_BIN" "$CLI" run
  assert_eq 0 "$CAPTURE_STATUS" "portal recorder command failed: $CAPTURE_OUTPUT"
  actual="$(<"$recorder_log")"
  expected="$(printf '<%s>\n' \
    -w portal \
    -s '1280x720' \
    -f '60' \
    -c mp4 \
    -r '75' \
    -replay-storage disk \
    -bm cbr \
    -q '12345' \
    -k h264 \
    -fm cfr \
    -fallback-cpu-encoding yes \
    -sc "$callback_path" \
    -o "$output_dir" \
    -restore-portal-session yes \
    -a default_output)"
  assert_eq "$expected" "$actual" "portal recorder arguments do not restore the portal session"
}

test_config_values_are_data() {
  local marker="$CASE_DIR/config-injection-ran"
  local monitor="\$(touch $marker)"

  make_fake_systemctl
  write_test_config "$monitor" 120 none false "$CASE_DIR/replays"
  [[ ! -e "$marker" ]] || fail "writing the injection-looking value unexpectedly executed it"

  run_capture "$BASH_BIN" "$CLI" status
  assert_eq 0 "$CAPTURE_STATUS" "data-like config value was rejected: $CAPTURE_OUTPUT"
  assert_contains "$CAPTURE_OUTPUT" "Display:       $monitor" "monitor value was not parsed literally"
  [[ ! -e "$marker" ]] || fail "loading the config executed its monitor value"
}

test_oversized_ram_config() {
  local recorder_log="$CASE_DIR/recorder-arguments"
  local output_dir="$CASE_DIR/unsafe-ram-replays"

  FAKE_GSR_LOG="$recorder_log"
  export FAKE_GSR_LOG
  make_fake_recorder
  write_test_config screen 86400 none false "$output_dir" ram 200000

  run_capture "$BASH_BIN" "$CLI" run
  assert_eq 1 "$CAPTURE_STATUS" "an unsafe RAM buffer configuration should be rejected"
  assert_eq 'Error: The estimated RAM buffer exceeds 8192 MiB. Choose disk storage or lower the duration/bitrate.' \
    "$CAPTURE_OUTPUT" "unsafe RAM buffer error is incorrect"
  [[ ! -e "$recorder_log" ]] || fail "recorder was invoked for an unsafe RAM configuration"
  [[ ! -e "$output_dir" ]] || fail "unsafe RAM validation occurred after creating the output directory"
}

test_required_output_filesystem() {
  local recorder_log="$CASE_DIR/recorder-arguments"
  local output_dir="$CASE_DIR/external/replays"
  local callback_path="$HOME/.local/bin/gsr-replay-callback"

  FAKE_GSR_LOG="$recorder_log"
  export FAKE_GSR_LOG
  make_fake_recorder
  make_fake_findmnt
  mkdir -p "$(dirname -- "$callback_path")" "$(dirname -- "$output_dir")"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$callback_path"
  chmod +x "$callback_path"
  write_test_config screen 120 none false "$output_dir" disk 12345 A1B2-C3D4

  FAKE_FINDMNT_UUID=FFFF-0000
  export FAKE_FINDMNT_UUID
  run_capture "$BASH_BIN" "$CLI" run
  assert_eq 1 "$CAPTURE_STATUS" "recording should fail on the wrong output filesystem"
  [[ ! -e "$recorder_log" ]] || fail "recorder started on the wrong filesystem"

  FAKE_FINDMNT_UUID=A1B2-C3D4
  export FAKE_FINDMNT_UUID
  run_capture "$BASH_BIN" "$CLI" run
  assert_eq 0 "$CAPTURE_STATUS" "recording should start on the required filesystem: $CAPTURE_OUTPUT"
  [[ -e "$recorder_log" ]] || fail "recorder did not start on the required filesystem"
}

test_output_verification_and_doctor() {
  local output_dir="$CASE_DIR/external/replays"
  local callback_path="$HOME/.local/bin/gsr-replay-callback"

  make_fake_findmnt
  make_fake_systemctl
  install_expected_service
  mkdir -p "$(dirname -- "$callback_path")" "$output_dir"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$callback_path"
  chmod +x "$callback_path"
  write_test_config portal 120 none false "$output_dir" disk 12345 A1B2-C3D4

  FAKE_FINDMNT_UUID=FFFF-0000
  FAKE_SYSTEMCTL_STATE=active
  export FAKE_FINDMNT_UUID FAKE_SYSTEMCTL_STATE
  run_capture "$BASH_BIN" "$CLI" verify-output "$output_dir" A1B2-C3D4
  assert_eq 1 "$CAPTURE_STATUS" "verify-output should fail while required storage is absent"

  run_capture "$BASH_BIN" "$CLI" doctor
  assert_eq 1 "$CAPTURE_STATUS" "doctor should fail while required storage is absent"
  assert_contains "$CAPTURE_OUTPUT" 'Output filesystem' "doctor omits the unavailable required filesystem"

  run_capture "$BASH_BIN" "$CLI" status-json
  assert_eq 0 "$CAPTURE_STATUS" "status-json should report unavailable storage without crashing"
  assert_contains "$CAPTURE_OUTPUT" '"alt":"failed"' "status-json does not surface unavailable storage"

  FAKE_FINDMNT_UUID=A1B2-C3D4
  export FAKE_FINDMNT_UUID
  run_capture "$BASH_BIN" "$CLI" verify-output "$output_dir" A1B2-C3D4
  assert_eq 0 "$CAPTURE_STATUS" "verify-output should accept the configured mounted filesystem: $CAPTURE_OUTPUT"
}

test_missing_config_blocks_start_paths() {
  make_fake_systemctl
  make_fake_recorder
  install_expected_service

  run_capture "$BASH_BIN" "$CLI" run
  assert_eq 1 "$CAPTURE_STATUS" "recorder run should require completed setup"
  assert_contains "$CAPTURE_OUTPUT" 'No configuration found' "run omits the missing configuration error"

  run_capture "$BASH_BIN" "$CLI" start
  assert_eq 1 "$CAPTURE_STATUS" "service start should require completed setup"
  assert_contains "$CAPTURE_OUTPUT" 'No configuration found' "start omits the missing configuration error"

  run_capture "$BASH_BIN" "$CLI" status
  assert_eq 1 "$CAPTURE_STATUS" "human status should fail without configuration"

  run_capture "$BASH_BIN" "$CLI" status-json
  assert_eq 0 "$CAPTURE_STATUS" "JSON status should remain machine-readable without configuration"
  assert_contains "$CAPTURE_OUTPUT" '"alt":"failed"' "JSON status does not report missing setup"
}

test_save_active() {
  local systemctl_log="$CASE_DIR/systemctl.log"
  local notify_log="$CASE_DIR/notify.log"
  local expected_notify

  : >"$systemctl_log"
  : >"$notify_log"
  FAKE_SYSTEMCTL_LOG="$systemctl_log"
  FAKE_SYSTEMCTL_STATE=active
  FAKE_NOTIFY_LOG="$notify_log"
  export FAKE_SYSTEMCTL_LOG FAKE_SYSTEMCTL_STATE FAKE_NOTIFY_LOG
  make_fake_systemctl
  make_fake_notify_send
  install_expected_service
  write_test_config screen 120 default_output true "$CASE_DIR/replays"

  run_capture "$BASH_BIN" "$CLI" save
  assert_eq 0 "$CAPTURE_STATUS" "saving an active replay failed: $CAPTURE_OUTPUT"
  assert_eq 'Replay save requested.' "$CAPTURE_OUTPUT" "active save confirmation is incorrect"
  assert_eq $'--user show gsr-replay.service --property=FragmentPath --value\n--user show gsr-replay.service --property=DropInPaths --value\n--user is-active --quiet gsr-replay.service\n--user kill --kill-whom=main --signal=SIGUSR1 gsr-replay.service' \
    "$(<"$systemctl_log")" "active save sent incorrect systemctl commands"
  expected_notify="$(printf '<%s>\n' \
    '--app-name=GSR Replay' \
    '--urgency=normal' \
    '--expire-time=2500' \
    'Saving replay clip' \
    'Saving the last 2 minutes.')"
  assert_eq "$expected_notify" "$(<"$notify_log")" "active save notification is incorrect"
}

test_save_inactive() {
  local systemctl_log="$CASE_DIR/systemctl.log"
  local notify_log="$CASE_DIR/notify.log"
  local expected_notify

  : >"$systemctl_log"
  : >"$notify_log"
  FAKE_SYSTEMCTL_LOG="$systemctl_log"
  FAKE_SYSTEMCTL_STATE=inactive
  FAKE_NOTIFY_LOG="$notify_log"
  export FAKE_SYSTEMCTL_LOG FAKE_SYSTEMCTL_STATE FAKE_NOTIFY_LOG
  make_fake_systemctl
  make_fake_notify_send
  install_expected_service
  write_test_config screen 120 default_output true "$CASE_DIR/replays"

  run_capture "$BASH_BIN" "$CLI" save
  assert_eq 1 "$CAPTURE_STATUS" "saving an inactive replay should fail after starting it"
  assert_eq 'Error: Replay buffer was not running. It has been started; try again in a moment.' \
    "$CAPTURE_OUTPUT" "inactive save error is incorrect"
  assert_eq $'--user show gsr-replay.service --property=FragmentPath --value\n--user show gsr-replay.service --property=DropInPaths --value\n--user is-active --quiet gsr-replay.service\n--user start gsr-replay.service' \
    "$(<"$systemctl_log")" "inactive save sent incorrect systemctl commands"
  expected_notify="$(printf '<%s>\n' \
    '--app-name=GSR Replay' \
    '--urgency=normal' \
    '--expire-time=5000' \
    'Replay buffer is starting' \
    'Try saving again in a moment.')"
  assert_eq "$expected_notify" "$(<"$notify_log")" "inactive save notification is incorrect"
}

test_callback_notifications() {
  local notify_log="$CASE_DIR/notify.log"
  local installed_dir="$HOME/.local/bin"
  local replay_file="$CASE_DIR/a replay clip.mp4"
  local second_file="$CASE_DIR/notifications-disabled.mp4"
  local expected_notify first_log

  : >"$notify_log"
  : >"$replay_file"
  : >"$second_file"
  FAKE_NOTIFY_LOG="$notify_log"
  export FAKE_NOTIFY_LOG
  make_fake_notify_send
  mkdir -p "$installed_dir" || fail "could not create callback installation directory"
  cp "$CLI" "$installed_dir/gsr-replay"
  cp "$CALLBACK" "$installed_dir/gsr-replay-callback"
  chmod +x "$installed_dir/gsr-replay" "$installed_dir/gsr-replay-callback"
  write_test_config screen 120 default_output true "$CASE_DIR/replays"

  run_capture "$installed_dir/gsr-replay-callback" "$replay_file"
  assert_eq 0 "$CAPTURE_STATUS" "callback failed for a saved replay: $CAPTURE_OUTPUT"
  assert_eq '' "$CAPTURE_OUTPUT" "callback unexpectedly wrote output"
  expected_notify="$(printf '<%s>\n' \
    '--app-name=GSR Replay' \
    '--urgency=normal' \
    '--expire-time=7000' \
    'Replay clip saved' \
    "$replay_file")"
  first_log="$(<"$notify_log")"
  assert_eq "$expected_notify" "$first_log" "callback save notification is incorrect"

  run_capture "$installed_dir/gsr-replay-callback" "$CASE_DIR/missing.mp4"
  assert_eq 0 "$CAPTURE_STATUS" "callback should ignore a missing replay file"
  assert_eq "$first_log" "$(<"$notify_log")" "callback notified for a missing replay file"

  write_test_config screen 120 default_output false "$CASE_DIR/replays"
  run_capture "$installed_dir/gsr-replay-callback" "$second_file"
  assert_eq 0 "$CAPTURE_STATUS" "callback failed when notifications were disabled"
  assert_eq "$first_log" "$(<"$notify_log")" "callback ignored the notifications setting"
}

test_waybar_json() {
  local monitor='DP-"1\test'
  local expected

  make_fake_systemctl
  write_test_config "$monitor" 120 default_output true "$CASE_DIR/replays"

  FAKE_SYSTEMCTL_STATE=active
  export FAKE_SYSTEMCTL_STATE
  run_capture "$BASH_BIN" "$CLI" waybar
  assert_eq 0 "$CAPTURE_STATUS" "active Waybar status failed: $CAPTURE_OUTPUT"
  assert_waybar_json "$CAPTURE_OUTPUT"
  expected='{"text":"REC","alt":"active","tooltip":"Replay buffer is active\nDisplay: DP-\"1\\test\nBuffer: 2 minutes\nLeft-click: Save clip\nRight-click: Stop","class":"active"}'
  assert_eq "$expected" "$CAPTURE_OUTPUT" "active Waybar JSON is incorrect or improperly escaped"

  run_capture "$BASH_BIN" "$CLI" status-json
  assert_eq 0 "$CAPTURE_STATUS" "desktop-neutral JSON status failed: $CAPTURE_OUTPUT"
  assert_eq "$expected" "$CAPTURE_OUTPUT" "status-json and the Waybar compatibility alias differ"

  FAKE_SYSTEMCTL_STATE=inactive
  export FAKE_SYSTEMCTL_STATE
  run_capture "$BASH_BIN" "$CLI" waybar
  assert_eq 0 "$CAPTURE_STATUS" "inactive Waybar status failed: $CAPTURE_OUTPUT"
  assert_waybar_json "$CAPTURE_OUTPUT"
  expected='{"text":"REC","alt":"inactive","tooltip":"Replay buffer is off\nRight-click: Start","class":"inactive"}'
  assert_eq "$expected" "$CAPTURE_OUTPUT" "inactive Waybar JSON is incorrect"

  FAKE_SYSTEMCTL_STATE=failed
  export FAKE_SYSTEMCTL_STATE
  run_capture "$BASH_BIN" "$CLI" waybar
  assert_eq 0 "$CAPTURE_STATUS" "failed Waybar status failed: $CAPTURE_OUTPUT"
  assert_waybar_json "$CAPTURE_OUTPUT"
  expected='{"text":"REC","alt":"failed","tooltip":"Replay buffer failed\nRight-click: Start again","class":"failed"}'
  assert_eq "$expected" "$CAPTURE_OUTPUT" "failed Waybar JSON is incorrect"
}

test_service_fragment_mismatch() {
  local expected_service="$XDG_CONFIG_HOME/systemd/user/gsr-replay.service"
  local overriding_service="$CASE_DIR/legacy-gsr-replay.service"

  make_fake_systemctl
  mkdir -p "$(dirname -- "$expected_service")"
  printf '[Service]\nExecStart=/bin/true\n' >"$expected_service"
  printf '[Service]\nExecStart=/bin/false\n' >"$overriding_service"
  FAKE_SYSTEMCTL_FRAGMENT="$overriding_service"
  export FAKE_SYSTEMCTL_FRAGMENT
  write_test_config screen 120 none false "$CASE_DIR/replays"

  run_capture "$BASH_BIN" "$CLI" start
  assert_eq 1 "$CAPTURE_STATUS" "a shadowing user unit should block service control"
  assert_contains "$CAPTURE_OUTPUT" "The loaded user service is $overriding_service" \
    "the shadowing unit error does not identify the effective fragment"
  assert_contains "$CAPTURE_OUTPUT" "expects $expected_service" \
    "the shadowing unit error does not identify the expected fragment"
}

test_service_dropin_mismatch() {
  make_fake_systemctl
  install_expected_service
  FAKE_SYSTEMCTL_DROPINS="$CASE_DIR/override.conf"
  export FAKE_SYSTEMCTL_DROPINS
  write_test_config screen 120 none false "$CASE_DIR/replays"

  run_capture "$BASH_BIN" "$CLI" start
  assert_eq 1 "$CAPTURE_STATUS" "a service drop-in should block service control"
  assert_contains "$CAPTURE_OUTPUT" "unsupported drop-ins: $FAKE_SYSTEMCTL_DROPINS" \
    "the drop-in error does not identify the effective override"
}

test_status_json_rejects_arithmetic_injection() {
  local marker="$CASE_DIR/arithmetic-injection-ran"
  local seconds="BASH_VERSINFO[\$(touch $marker)0]"

  make_fake_systemctl
  write_test_config screen "$seconds" none false "$CASE_DIR/replays"
  FAKE_SYSTEMCTL_STATE=active
  export FAKE_SYSTEMCTL_STATE

  run_capture "$BASH_BIN" "$CLI" status-json
  assert_eq 1 "$CAPTURE_STATUS" "status-json should reject a non-integer duration"
  [[ ! -e "$marker" ]] || fail "status-json executed arithmetic syntax from configuration"
}

test_status_json_handles_leading_zero_duration() {
  make_fake_systemctl
  write_test_config screen 0360 none false "$CASE_DIR/replays"
  FAKE_SYSTEMCTL_STATE=active
  export FAKE_SYSTEMCTL_STATE

  run_capture "$BASH_BIN" "$CLI" status-json
  assert_eq 0 "$CAPTURE_STATUS" "a decimal duration with leading zero should remain valid: $CAPTURE_OUTPUT"
  assert_contains "$CAPTURE_OUTPUT" 'Buffer: 6 minutes' "duration was reinterpreted as octal"
}

test_status_json_rejects_control_characters() {
  local monitor="DP-1"$'\b'"hidden"

  make_fake_systemctl
  write_test_config "$monitor" 120 none false "$CASE_DIR/replays"
  FAKE_SYSTEMCTL_STATE=active
  export FAKE_SYSTEMCTL_STATE

  run_capture "$BASH_BIN" "$CLI" status-json
  assert_eq 1 "$CAPTURE_STATUS" "status-json should reject C0 control characters"
}

test_recorder_uses_isolated_process_name() {
  assert_file_contains "$CLI" 'exec -a gsr-replay-buffer gpu-screen-recorder' \
    "replay recorder does not use its isolated process identity"
}

test_waybar_rejects_unsafe_layouts() {
  local waybar_dir="$XDG_CONFIG_HOME/waybar"
  local inline_config="$waybar_dir/inline.jsonc"
  local multi_config="$waybar_dir/multi.jsonc"
  local style="$waybar_dir/style.css"
  local inline_snapshot="$CASE_DIR/inline.before"
  local multi_snapshot="$CASE_DIR/multi.before"
  local style_snapshot="$CASE_DIR/style.before"
  local -a config_backups style_backups

  make_fake_omarchy
  mkdir -p "$waybar_dir" || fail "could not create Waybar directory"
  cat >"$inline_config" <<'EOF'
{
  "modules-left": [],
  "modules-center": [],
  "modules-right": ["tray"]
}
EOF
  cat >"$multi_config" <<'EOF'
[
  {
    "modules-right": [
      "tray"
    ]
  },
  {
    "modules-right": [
      "clock"
    ]
  }
  ]
EOF
  printf '#waybar { color: white; }\n' >"$style"
  cp "$inline_config" "$inline_snapshot"
  cp "$multi_config" "$multi_snapshot"
  cp "$style" "$style_snapshot"

  run_capture "$BASH_BIN" "$CLI" waybar-install "$inline_config" "$style" right
  assert_eq 1 "$CAPTURE_STATUS" "inline Waybar module arrays should be rejected"
  assert_contains "$CAPTURE_OUTPUT" 'Unsupported Waybar layout: modules-right must use a multiline array.' \
    "inline Waybar rejection did not explain the required layout"
  assert_files_equal "$inline_snapshot" "$inline_config" "inline Waybar config was modified after rejection"
  assert_files_equal "$style_snapshot" "$style" "stylesheet was modified after rejecting inline config"

  run_capture "$BASH_BIN" "$CLI" waybar-install "$multi_config" "$style" right
  assert_eq 1 "$CAPTURE_STATUS" "multi-bar Waybar configs should be rejected"
  assert_contains "$CAPTURE_OUTPUT" 'Only a single-object Waybar config is supported; no changes were made.' \
    "multi-bar Waybar rejection did not explain the supported layout"
  assert_files_equal "$multi_snapshot" "$multi_config" "multi-bar Waybar config was modified after rejection"
  assert_files_equal "$style_snapshot" "$style" "stylesheet was modified after rejecting multi-bar config"

  shopt -s nullglob
  config_backups=("$inline_config".gsr-replay.bak.* "$multi_config".gsr-replay.bak.*)
  style_backups=("$style".gsr-replay.bak.*)
  shopt -u nullglob
  assert_eq 0 "${#config_backups[@]}" "rejected Waybar configs unexpectedly received backups"
  assert_eq 0 "${#style_backups[@]}" "stylesheet unexpectedly received a backup after config rejection"
}

test_waybar_moves_managed_module() {
  local waybar_dir="$XDG_CONFIG_HOME/waybar"
  local config="$waybar_dir/config.jsonc"
  local style="$waybar_dir/style.css"
  local manifest="$XDG_CONFIG_HOME/gsr-replay/waybar-install"
  local content
  local -a config_backups style_backups

  make_fake_omarchy
  mkdir -p "$waybar_dir" || fail "could not create Waybar directory"
  cat >"$config" <<'EOF'
{
  "modules-left": [
    "clock"
  ],
  "modules-center": [
  ],
  "modules-right": [
    "tray"
  ]
}
EOF
  printf '#waybar { color: white; }\n' >"$style"

  run_capture "$BASH_BIN" "$CLI" waybar-install "$config" "$style" right
  assert_eq 0 "$CAPTURE_STATUS" "initial right-side Waybar install failed: $CAPTURE_OUTPUT"
  content="$(<"$config")"
  assert_contains "$content" $'"modules-right": [\n    // gsr-replay:module-start\n    "custom/gsr-replay",' \
    "managed module was not initially installed on the right"

  run_capture "$BASH_BIN" "$CLI" waybar-install "$config" "$style" left
  assert_eq 0 "$CAPTURE_STATUS" "moving the managed Waybar module to the left failed: $CAPTURE_OUTPUT"
  content="$(<"$config")"
  assert_contains "$content" $'"modules-left": [\n    // gsr-replay:module-start\n    "custom/gsr-replay",' \
    "managed module was not moved to the left"
  assert_not_contains "$content" $'"modules-right": [\n    // gsr-replay:module-start' \
    "managed module remains on the right after reinstall"
  assert_contains "$content" $'"modules-right": [\n    "tray"' "existing right-side modules changed during the move"
  count_occurrences "$content" '"custom/gsr-replay"'
  assert_eq 1 "$OCCURRENCES" "moving the managed module created a duplicate"
  count_occurrences "$content" '// gsr-replay:module-start'
  assert_eq 1 "$OCCURRENCES" "moving the managed module left duplicate marker blocks"
  assert_eq "$config"$'\n'"$style"$'\nleft' "$(<"$manifest")" "Waybar manifest did not record the new position"

  shopt -s nullglob
  config_backups=("$config".gsr-replay.bak.*)
  style_backups=("$style".gsr-replay.bak.*)
  shopt -u nullglob
  assert_eq 2 "${#config_backups[@]}" "moving the module did not create one config backup per change"
  assert_eq 1 "${#style_backups[@]}" "moving the module unnecessarily rewrote the managed stylesheet"
}

test_malformed_css_markers_are_preserved() {
  local waybar_dir="$XDG_CONFIG_HOME/waybar"
  local config="$waybar_dir/config.jsonc"
  local style="$waybar_dir/style.css"
  local style_snapshot="$CASE_DIR/style.before"
  local -a style_backups

  make_fake_omarchy
  mkdir -p "$waybar_dir" || fail "could not create Waybar directory"
  cat >"$config" <<'EOF'
{
  "modules-left": [
  ],
  "modules-center": [
  ],
  "modules-right": [
    "tray"
  ]
}
EOF
  cat >"$style" <<'EOF'
#waybar { color: white; }
/* gsr-replay:start */
#custom-gsr-replay { color: red; }
#sentinel { color: green; }
EOF
  cp "$style" "$style_snapshot"

  run_capture "$BASH_BIN" "$CLI" waybar-install "$config" "$style" right
  assert_eq 1 "$CAPTURE_STATUS" "install should reject malformed CSS markers"
  assert_contains "$CAPTURE_OUTPUT" "Malformed gsr-replay CSS markers in $style; no changes were made." \
    "install did not report malformed CSS markers"
  assert_files_equal "$style_snapshot" "$style" "install truncated or rewrote malformed CSS"

  run_capture "$BASH_BIN" "$CLI" waybar-uninstall "$config" "$style"
  assert_eq 1 "$CAPTURE_STATUS" "uninstall should reject malformed CSS markers"
  assert_contains "$CAPTURE_OUTPUT" "Malformed gsr-replay CSS markers in $style; no changes were made." \
    "uninstall did not report malformed CSS markers"
  assert_files_equal "$style_snapshot" "$style" "uninstall truncated or rewrote malformed CSS"
  assert_file_contains "$style" '#sentinel { color: green; }' "malformed CSS lost trailing content"

  shopt -s nullglob
  style_backups=("$style".gsr-replay.bak.*)
  shopt -u nullglob
  assert_eq 0 "${#style_backups[@]}" "malformed CSS was backed up despite remaining unchanged"
}

test_waybar_install_idempotency_and_uninstall() {
  local waybar_dir="$XDG_CONFIG_HOME/waybar"
  local config="$waybar_dir/config.jsonc"
  local style="$waybar_dir/style.css"
  local module="$XDG_CONFIG_HOME/gsr-replay/waybar.jsonc"
  local config_content config_after style_after
  local -a config_backups style_backups

  make_fake_omarchy
  mkdir -p "$waybar_dir" || fail "could not create Waybar directory"
  cat >"$config" <<'EOF'
{
  "modules-left": [
    "clock"
  ],
  "modules-center": [
  ],
  "modules-right": [
    "tray"
  ]
}
EOF
  printf '#waybar { color: white; }\n' >"$style"

  run_capture "$BASH_BIN" "$CLI" waybar-install "$config" "$style" right
  assert_eq 0 "$CAPTURE_STATUS" "Waybar install failed: $CAPTURE_OUTPUT"
  assert_contains "$CAPTURE_OUTPUT" "Waybar integration installed in $config." "Waybar install reported the wrong config"
  [[ -f "$module" ]] || fail "Waybar module include was not created"
  assert_file_contains "$module" '"return-type": "json"' "Waybar module does not request JSON"
  config_content="$(<"$config")"
  count_occurrences "$config_content" "$module"
  assert_eq 1 "$OCCURRENCES" "Waybar module include was not installed exactly once"
  count_occurrences "$config_content" '"custom/gsr-replay"'
  assert_eq 1 "$OCCURRENCES" "Waybar custom module was not installed exactly once"
  count_occurrences "$(<"$style")" '/* gsr-replay:start */'
  assert_eq 1 "$OCCURRENCES" "Waybar style block was not installed exactly once"

  shopt -s nullglob
  config_backups=("$config".gsr-replay.bak.*)
  style_backups=("$style".gsr-replay.bak.*)
  shopt -u nullglob
  assert_eq 1 "${#config_backups[@]}" "Waybar config backup was not created"
  assert_eq 1 "${#style_backups[@]}" "Waybar style backup was not created"

  config_after="$(<"$config")"
  style_after="$(<"$style")"
  run_capture "$BASH_BIN" "$CLI" waybar-install "$config" "$style" right
  assert_eq 0 "$CAPTURE_STATUS" "second Waybar install failed: $CAPTURE_OUTPUT"
  assert_eq "$config_after" "$(<"$config")" "second Waybar install changed the config"
  assert_eq "$style_after" "$(<"$style")" "second Waybar install changed the stylesheet"
  shopt -s nullglob
  config_backups=("$config".gsr-replay.bak.*)
  style_backups=("$style".gsr-replay.bak.*)
  shopt -u nullglob
  assert_eq 1 "${#config_backups[@]}" "idempotent install created another config backup"
  assert_eq 1 "${#style_backups[@]}" "idempotent install created another style backup"

  run_capture "$BASH_BIN" "$CLI" waybar-uninstall "$config" "$style"
  assert_eq 0 "$CAPTURE_STATUS" "Waybar uninstall failed: $CAPTURE_OUTPUT"
  assert_eq 'Waybar integration removed.' "$CAPTURE_OUTPUT" "Waybar uninstall output is incorrect"
  [[ ! -e "$module" ]] || fail "Waybar module include remains after uninstall"
  config_content="$(<"$config")"
  assert_not_contains "$config_content" 'custom/gsr-replay' "Waybar module remains in config after uninstall"
  assert_not_contains "$config_content" "$module" "Waybar include remains in config after uninstall"
  assert_contains "$config_content" '"tray"' "Waybar uninstall removed an existing module"
  assert_not_contains "$(<"$style")" 'gsr-replay:start' "Waybar style remains after uninstall"
  assert_file_contains "$style" '#waybar { color: white; }' "Waybar uninstall removed existing styles"
}

test_symlinked_waybar_config() {
  local waybar_dir="$XDG_CONFIG_HOME/waybar"
  local profile_dir="$XDG_CONFIG_HOME/profiles"
  local target="$profile_dir/main.jsonc"
  local config="$waybar_dir/config.jsonc"
  local style="$waybar_dir/style.css"
  local module="$XDG_CONFIG_HOME/gsr-replay/waybar.jsonc"
  local -a target_backups link_backups

  make_fake_omarchy
  mkdir -p "$waybar_dir" "$profile_dir" || fail "could not create symlinked Waybar directories"
  cat >"$target" <<'EOF'
{
  "modules-left": [
  ],
  "modules-center": [
    "clock"
  ],
  "modules-right": [
  ]
}
EOF
  printf '#waybar {}\n' >"$style"
  ln -s '../profiles/main.jsonc' "$config"

  run_capture "$BASH_BIN" "$CLI" waybar-install "$config" "$style" center
  assert_eq 0 "$CAPTURE_STATUS" "install through a symlinked Waybar config failed: $CAPTURE_OUTPUT"
  [[ -L "$config" ]] || fail "Waybar config symlink was replaced during install"
  assert_file_contains "$target" '"custom/gsr-replay"' "symlink target was not patched"
  assert_file_contains "$target" "$module" "symlink target did not receive the module include"
  assert_contains "$CAPTURE_OUTPUT" "installed in $target." "Waybar install did not report the canonical config path"

  shopt -s nullglob
  target_backups=("$target".gsr-replay.bak.*)
  link_backups=("$config".gsr-replay.bak.*)
  shopt -u nullglob
  assert_eq 1 "${#target_backups[@]}" "symlink target backup was not created"
  assert_eq 0 "${#link_backups[@]}" "backup was incorrectly created beside the symlink"

  run_capture "$BASH_BIN" "$CLI" waybar-uninstall "$config" "$style"
  assert_eq 0 "$CAPTURE_STATUS" "uninstall through a symlinked Waybar config failed: $CAPTURE_OUTPUT"
  [[ -L "$config" ]] || fail "Waybar config symlink was replaced during uninstall"
  assert_not_contains "$(<"$target")" 'custom/gsr-replay' "symlink target retains the module after uninstall"
  assert_not_contains "$(<"$target")" "$module" "symlink target retains the include after uninstall"
  assert_file_contains "$target" '"clock"' "symlink target lost existing configuration"
}

test_install_no_setup() {
  local systemctl_log="$CASE_DIR/systemctl.log"
  local installed_bin="$HOME/.local/bin"
  local installed_service="$XDG_CONFIG_HOME/systemd/user/gsr-replay.service"

  : >"$systemctl_log"
  FAKE_SYSTEMCTL_LOG="$systemctl_log"
  FAKE_SYSTEMCTL_STATE=inactive
  export FAKE_SYSTEMCTL_LOG FAKE_SYSTEMCTL_STATE
  make_fake_systemctl

  run_capture "$BASH_BIN" "$INSTALLER" --no-setup
  assert_eq 0 "$CAPTURE_STATUS" "install.sh --no-setup failed: $CAPTURE_OUTPUT"
  assert_contains "$CAPTURE_OUTPUT" "Installed gsr-replay in $installed_bin." "installer reported the wrong destination"
  assert_contains "$CAPTURE_OUTPUT" "Run \"$installed_bin/gsr-replay setup\"" "installer omitted the setup instruction"
  assert_not_contains "$CAPTURE_OUTPUT" 'GSR Replay setup' "--no-setup unexpectedly ran onboarding"
  [[ -x "$installed_bin/gsr-replay" ]] || fail "installer did not install the CLI as executable"
  [[ -x "$installed_bin/gsr-replay-callback" ]] || fail "installer did not install the callback as executable"
  [[ -f "$installed_service" ]] || fail "installer did not install the user service under XDG_CONFIG_HOME"
  assert_files_equal "$CLI" "$installed_bin/gsr-replay" "installed CLI differs from the source"
  assert_files_equal "$CALLBACK" "$installed_bin/gsr-replay-callback" "installed callback differs from the source"
  assert_files_equal "$ROOT_DIR/systemd/gsr-replay.service" "$installed_service" "installed service differs from the source"
  assert_eq '--user daemon-reload' "$(<"$systemctl_log")" "installer sent incorrect systemctl commands"
  [[ ! -e "$XDG_CONFIG_HOME/gsr-replay/config" ]] || fail "--no-setup unexpectedly created a replay config"
}

run_test() {
  local description="$1" function_name="$2"
  ((TEST_NUMBER += 1))
  if (setup_case; "$function_name"); then
    printf 'ok %d - %s\n' "$TEST_NUMBER" "$description"
    ((PASSED += 1))
  else
    printf 'not ok %d - %s\n' "$TEST_NUMBER" "$description"
    ((FAILED += 1))
  fi
}

printf 'TAP version 13\n'
printf '1..24\n'
run_test 'help and version commands' test_help_and_version
run_test 'recorder argument construction and audio omission' test_recorder_arguments
run_test 'portal recording restores its portal session' test_portal_recorder_arguments
run_test 'config values are parsed as data without shell evaluation' test_config_values_are_data
run_test 'unsafe oversized RAM buffers are rejected' test_oversized_ram_config
run_test 'required output filesystem UUID is enforced' test_required_output_filesystem
run_test 'output verification and doctor enforce required storage' test_output_verification_and_doctor
run_test 'missing configuration blocks every start path' test_missing_config_blocks_start_paths
run_test 'saving an active replay signals the recorder' test_save_active
run_test 'saving an inactive replay starts the service' test_save_inactive
run_test 'callback notifications respect file and config state' test_callback_notifications
run_test 'Waybar emits valid active, inactive, and failed JSON' test_waybar_json
run_test 'service control rejects a shadowing user unit' test_service_fragment_mismatch
run_test 'service control rejects execution-changing drop-ins' test_service_dropin_mismatch
run_test 'status-json rejects arithmetic injection in numeric config' test_status_json_rejects_arithmetic_injection
run_test 'status-json treats leading-zero durations as decimal' test_status_json_handles_leading_zero_duration
run_test 'status-json rejects JSON-breaking control characters' test_status_json_rejects_control_characters
run_test 'recorder uses the replay-specific process identity' test_recorder_uses_isolated_process_name
run_test 'Waybar rejects inline and multi-bar layouts without modification' test_waybar_rejects_unsafe_layouts
run_test 'Waybar reinstall moves its managed module between positions' test_waybar_moves_managed_module
run_test 'malformed Waybar CSS markers fail without truncation' test_malformed_css_markers_are_preserved
run_test 'Waybar install is idempotent and uninstall is clean' test_waybar_install_idempotency_and_uninstall
run_test 'symlinked Waybar configs preserve and patch their target' test_symlinked_waybar_config
run_test 'install.sh --no-setup stays inside an isolated home' test_install_no_setup

printf '# %d passed, %d failed\n' "$PASSED" "$FAILED"
((FAILED == 0))
