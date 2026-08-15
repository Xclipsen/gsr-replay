# Changelog

All notable changes to this project are documented here.

## Unreleased

- Show the Waybar replay state as a red or gray dot and place it after the tray expander when available.
- Add setup-managed, configurable Hyprland hotkeys for toggling and saving replays.
- Capture desktop and microphone audio separately and mix the microphone only during headphone-active replay sections.
- Track audio output changes with an event-driven systemd companion service.
- Add optional delayed clip archiving from local staging to UUID-validated external storage.
- Add archive destination and delay configuration to the setup wizard.
- Make archiving restart-safe with verified, synchronized temporary copies and explicit per-clip transaction recovery.
- Preserve and retry clips after interrupted audio finalization or archive copies.
- Bind audio recovery state to the staged file and prevent delayed callbacks from consuming newer save requests.
- Serialize save callbacks with archive runs and reject overlapping save requests.
- Validate media streams and both staging and archive filesystems while continuing past per-file failures.
- Pin archive storage during setup and fail closed instead of creating an external-drive path on the system disk.
- Extend diagnostics to cover the archive timer, archive storage, and recovery dependencies.
- Reject shadowed auxiliary systemd units, unsafe state-file symlinks, and archive path control bytes.
- Keep Arch package metadata aligned with the FFmpeg runtime dependency.
- Probe NVIDIA H.264 encoding at startup and fall back from NVENC to Vulkan GPU encoding, then CPU encoding, when an FFmpeg update raises the required NVENC API.
- Prevent permanent encoder incompatibilities from entering a systemd restart loop.

## 1.1.0 - 2026-07-22

- Distinguish the replay buffer from ordinary GPU Screen Recorder processes.
- Detect user systemd units that shadow the packaged service.
- Add a desktop-neutral JSON status command for Quickshell integrations.
- Make Waybar reload feature detection compatible with Omarchy 4.
- Add package-time syntax, ShellCheck, and behavior tests.
- Validate optional replay filesystem UUIDs before recording or saving.
- Reject service drop-ins and JSON-breaking configuration control bytes.
- Treat validated numeric settings as decimal even with leading zeroes.

## 1.0.0 - 2026-07-22

- Add interactive English onboarding with display and audio discovery.
- Add configurable replay duration, quality, storage, and output settings.
- Add a hardened systemd user service and desktop notifications.
- Add safe, optional Waybar integration with click controls and backups.
- Add status, diagnostics, and replay management commands.
- Add an Arch Linux package and release-ready PKGBUILD.
- Add automated ShellCheck, integration, and packaging tests.
