# Changelog

All notable changes to this project are documented here.

## Unreleased

- Show the Waybar replay state as a red or gray dot and place it after the tray expander when available.
- Add setup-managed, configurable Hyprland hotkeys for toggling and saving replays.

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
