# Changelog

## v1.2.0

Fully compatible with v1.0 and v1.1: PCs can be updated one at a time, and old and new versions keep messaging each other.

### Added
- **Encryption.** Messages between two v1.2+ PCs are encrypted with AES-256 and signed (encrypt-then-MAC). The keys are derived from the existing office key, so nothing new has to be distributed. Messages to and from older PCs still use the older, unencrypted format, and the Send window and pop-ups show which is which.
- **Messages are addressed to one PC.** A PC refuses a message meant for another PC, so after a router restart (when PCs can swap IP addresses) a message can never pop up on the wrong screen. The sender sees "address changed, refreshing" and can send again a moment later.
- **Versions everywhere.** The tray menu and Send window show this PC's version; the Send window shows each person's version.
- **Update notice.** The tray menu and Send window show "Update available" when a newer version runs on another office PC (works without internet) or is published on GitHub (checked once a day; turn off with `"UpdateCheck": false` in `config.json`).
- **`tools\Check-Office.bat`.** Read-only status table of every PC on the network: messenger version, file sharing, PCs with a different office key, set-up PCs that are switched off.
- `-ToPc` command-line option to send encrypted, addressed messages.

## v1.1

### Fixed
- The messenger no longer opens a console window, and keeps running when windows are closed. On PCs where Windows Terminal is the default terminal app, the old shortcuts ran it inside a visible terminal window, and closing that window stopped it. It now starts through `conhost.exe --headless`.
- Setup no longer fails with *"'powershell' is not recognized"* on PCs whose `PATH` is missing the PowerShell folder: PowerShell and other Windows tools are called by their full path.

## v1.0

First release: network sharing setup and Office Messenger.
