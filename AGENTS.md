# GSR Replay Contributor Guide

## Scope

Keep this repository desktop-independent. Omarchy-specific menus and widgets
belong in the Omarchy fork; this project exposes stable CLI and JSON contracts.

## Safety

- Never source `~/.config/gsr-replay/config`; parse it as data.
- Preserve replay videos and user configuration during normal removal.
- Never identify or stop recorders with broad `pgrep` or `pkill` patterns.
- Validate the effective systemd `FragmentPath` before controlling the service.
- Package installation must not enable or start recording.

## Checks

Run before committing:

```bash
bash -n bin/* install.sh uninstall.sh tests/run.sh packaging/arch/gsr-replay.install
shellcheck bin/* install.sh uninstall.sh tests/run.sh packaging/arch/gsr-replay.install
bash tests/run.sh
systemd-analyze --user verify systemd/gsr-replay.service
```

For releases, regenerate `.SRCINFO`, build the package from the exact release
archive, verify it with `namcap`, and publish SHA-256 digests.
