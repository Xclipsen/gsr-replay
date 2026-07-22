# Contributing

Contributions are welcome through GitHub issues and pull requests.

## Development Setup

GPU Screen Recorder is only required for manual runtime testing. The automated test suite uses isolated fake commands and does not start a recorder.

Run all local checks before opening a pull request:

```bash
shellcheck bin/* install.sh uninstall.sh tests/run.sh
bash tests/run.sh
systemd-analyze --user verify systemd/gsr-replay.service
```

For packaging changes, also run:

```bash
cd packaging/arch
makepkg --printsrcinfo | diff -u .SRCINFO -
namcap PKGBUILD
```

Keep user-facing text in English, preserve compatibility with Bash 4.3 or newer, and avoid adding required dependencies when a reliable shell implementation is practical.
