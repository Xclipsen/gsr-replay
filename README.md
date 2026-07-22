# GSR Replay

A small, production-ready instant replay controller for [GPU Screen Recorder](https://git.dec05eba.com/gpu-screen-recorder/about/). It provides guided onboarding, a resilient systemd user service, desktop notifications, and optional Waybar integration.

Omarchy 4 can consume the `status-json` command for native Quickshell integration without enabling the optional Waybar support.

## Features

- Interactive setup with automatic display and audio-source discovery
- Configurable resolution, frame rate, duration, bitrate, output directory, and RAM or disk buffering
- systemd user service with optional desktop-session autostart
- Safe clip saving through systemd process signaling
- Optional Waybar indicator with click controls and automatic config backups
- Desktop notifications when clips are saved or a stopped buffer is started by a save request
- Built-in status and dependency diagnostics
- Idempotent installer and clean uninstaller

## Requirements

- Linux with systemd user services
- Bash 4.3 or newer
- [GPU Screen Recorder](https://git.dec05eba.com/gpu-screen-recorder/about/)
- `notify-send` for optional desktop notifications
- Waybar for the optional status module

On Arch Linux, install the main dependencies with:

```bash
sudo pacman -S gpu-screen-recorder libnotify
```

## Install

```bash
git clone https://github.com/Xclipsen/gsr-replay.git
cd gsr-replay
./install.sh
```

The installer places the CLI in `~/.local/bin`, installs a systemd user unit, and opens the onboarding wizard. Make sure `~/.local/bin` is on your `PATH`.

Run the wizard again at any time:

```bash
gsr-replay setup
```

### Arch Package

An Arch Linux package definition is included in `packaging/arch`:

```bash
git clone https://github.com/Xclipsen/gsr-replay.git
cd gsr-replay/packaging/arch
makepkg -si
gsr-replay setup
```

The package installs the CLI system-wide and provides a systemd user service. It does not enable or start recording before onboarding is completed. The `PKGBUILD` is structured for a future AUR release.

The wizard lets you select:

- The display to capture, discovered from GPU Screen Recorder
- Output resolution and frame rate
- Replay duration and video bitrate
- Desktop audio, microphone, another audio device, or no audio
- RAM or disk replay-buffer storage
- Replay output directory
- Desktop notifications and automatic startup
- Optional Waybar integration and module position

All onboarding and CLI text is in English.

## Commands

```text
gsr-replay setup              Run onboarding
gsr-replay start              Start the replay buffer
gsr-replay stop               Stop the replay buffer
gsr-replay toggle             Start or stop the replay buffer
gsr-replay save               Save the current buffer
gsr-replay status             Show service and capture settings
gsr-replay status-json        Show machine-readable service status
gsr-replay doctor             Check the installation
gsr-replay list-monitors      List capture displays
gsr-replay list-audio         List audio sources
```

If `save` is called while the recorder is stopped, the service starts and asks you to try again after the buffer has collected footage.

## Waybar

During onboarding, choose **Install the Waybar status module**. The installer:

1. Creates `~/.config/gsr-replay/waybar.jsonc`.
2. Adds it through Waybar's supported `include` option.
3. Adds `custom/gsr-replay` to the selected left, center, or right module list. For safety, that list must use Waybar's usual multiline JSONC format.
4. Adds a small style block to the selected stylesheet.
5. Creates timestamped backups before changing either Waybar file.

Indicator controls:

- Left-click: save a replay clip
- Right-click: start or stop the replay buffer
- Red `REC`: active
- Dimmed `REC`: inactive
- Amber `REC`: service failed

Manual integration commands are also available:

```bash
gsr-replay waybar-install ~/.config/waybar/config.jsonc ~/.config/waybar/style.css right
gsr-replay waybar-uninstall
```

## Configuration

Configuration is stored in:

```text
~/.config/gsr-replay/config
```

The generated file is a private key/value data file and must not be sourced as shell code. Prefer `gsr-replay setup` over manual edits because the wizard validates every setting.

Replay videos default to `~/Videos/replay`. The uninstaller never removes replay videos.
When `GSR_REPLAY_REQUIRED_FS_UUID` is set by an integration, recording and
saving fail closed unless that exact filesystem is mounted below the output
directory. This prevents an unavailable external drive from redirecting clips
onto the system disk.

## Troubleshooting

Run:

```bash
gsr-replay doctor
journalctl --user -u gsr-replay.service -n 100 --no-pager
```

If a configured monitor is disconnected, rerun `gsr-replay setup` and select an available display or the desktop portal.

If the output directory is a symlink to an unmounted drive, the service exits without creating a directory in the symlink's place. Mount the drive and start the service again.

## Uninstall

```bash
./uninstall.sh
```

This removes the CLI, service, and Waybar integration while preserving configuration and replay videos. To also remove the configuration:

```bash
./uninstall.sh --purge
```

## Development

```bash
shellcheck bin/* install.sh uninstall.sh tests/run.sh
bash tests/run.sh
systemd-analyze --user verify systemd/gsr-replay.service
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the complete development and packaging checks. Release changes are tracked in [CHANGELOG.md](CHANGELOG.md).

## License

MIT. GPU Screen Recorder is a separate project licensed under GPL-3.0-only.
