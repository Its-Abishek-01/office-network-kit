# Office Network Kit

Set up the Windows PCs in an office so they can **see each other on the network** and **send pop-up messages to each other**: no server, no internet, no accounts, nothing to download. One file to run on each PC.

<p align="center">
  <img src="docs/screenshots/popup-message.png" alt="Incoming message pop-up" width="440">
</p>

A manager sends *"Please come to my desk"*. The message pops up on top of everything on that person's screen, and they answer with one click: **Coming now**, **Give me 5 min** or **OK, seen**.

## Features

**Network sharing setup**
- Marks the office network as **Private** (Windows hides PCs on Public networks)
- Turns on **Network Discovery** and **File and Printer Sharing**, for Private networks only
- Optionally gives each PC a clear name (for example `ACCOUNTS-01`)
- Keeps a list of every PC you set up (`office-pcs.csv`)

**Office Messenger**
- Pop-up messages that appear **on top of every window**, with a sound
- **One-click replies**, or type your own
- **Urgent** messages: red pop-up with an alert sound
- Quick messages: *Come to my desk*, *Call me*, *Meeting now*, *Check your email*
- Send to one person, several people or **everyone**
- Shows **who is online**, and whether each message was **delivered**
- Starts with Windows and sits in the system tray
- Message history, change your display name
- Messages are **signed with an office key**, so other devices on the network (phones, guests) can't send fake pop-ups

| Send window | Urgent message | Reply |
|---|---|---|
| <img src="docs/screenshots/send-window.png" width="300"> | <img src="docs/screenshots/popup-urgent.png" width="300"> | <img src="docs/screenshots/popup-reply.png" width="300"> |

## Requirements

- Windows 10 or Windows 11
- All PCs on the **same office network** (same router; cable or Wi-Fi)
- An administrator account on each PC (to run the setup)

Uses only what is built into Windows: Windows PowerShell 5.1 and WPF.

## Quick start

1. [Download the ZIP](../../archive/refs/heads/main.zip) and extract it to a pendrive.
2. On each office PC, double-click **`Setup-This-PC.bat`** and click **Yes**.
3. Confirm the PC is connected to your **office network**, then answer the questions. The setup asks before each part:
   1. **Network sharing**
   2. **Office Messenger**
4. The **first** PC creates a new **office key** (`messenger\messenger-key.txt`) in the kit. **Use the same kit for every other PC**, because PCs with different keys can't message each other.
5. If you renamed a PC, restart it when convenient.

To send a message, click the blue chat icon near the clock (or the *Office Messenger* shortcut on the Desktop), tick people, type and press **Send**.

> **Keep `messenger-key.txt` private.** Anyone with it can send pop-ups to your office PCs. Don't commit it, email it or share it. If it leaks, delete it from the kit, run the setup again on the first PC to create a new key, then re-run it on every other PC.

## How it works

```
Setup-This-PC.bat            run once on each PC (as admin)
 ├─ Part 1: network sharing  Private network profile, firewall rule groups, discovery services
 └─ Part 2: messenger        copy to C:\ProgramData\OfficeMessenger, firewall rule, shortcuts

OfficeMessenger.ps1          runs in the tray for the signed-in user
 ├─ who is online            UDP broadcast on port 51515 ("hello?" / "hello" every 60 s / "bye")
 ├─ messages                 TCP on port 51515, one JSON line, receiver answers OK or NO
 └─ security                 HMAC-SHA256 signature with the office key,
                             timestamp must be within 15 minutes, duplicate IDs ignored
```

- **Setup** is a `.bat` file so it can be double-clicked. It asks Windows for admin rights, then runs the PowerShell code embedded below its `#PSSTART` marker.
- The **firewall rule** for the messenger only allows port 51515, only for `powershell.exe`, only from the **local subnet** and only on **Private** networks.
- The messenger runs as the **signed-in user**, not as administrator.

| Location | What |
|---|---|
| `C:\ProgramData\OfficeMessenger\` | Program, office key, `config.json` (display name) |
| `%APPDATA%\OfficeMessenger\history.txt` | Each user's message history |
| Startup folder (all users) | Starts the messenger at sign-in |

**Command-line options** for `OfficeMessenger.ps1`:

| Option | Purpose |
|---|---|
| `-Show` | Open the Send window (used by the Desktop shortcut) |
| `-SendTo <ip> -Message "text" [-Urgent]` | Send one message from the command line |
| `-Preview <folder>` | Render the windows to PNG files with sample data (used for the screenshots) |

## Security and limitations

Please read this before using it in your office.

| | |
|---|---|
| **Not encrypted** | Messages are *signed* (they can't be faked without the key) but **not encrypted**. Anyone on the same network with a packet sniffer can read them. Don't send passwords or confidential information. |
| **Display names aren't verified** | Anyone with the key can choose any display name. The PC name shown under it is the real Windows computer name. |
| **Key readable on each PC** | Any user signed in to an office PC can read the key from `C:\ProgramData\OfficeMessenger`. Intended for offices where staff are trusted. |
| **One network only** | Discovery uses broadcast, which doesn't cross routers, so separate subnets or branches won't see each other. |
| **Clocks** | A PC whose clock is more than 15 minutes off will have its messages rejected. |
| **Replay window** | Seen message IDs are kept in memory only, so a captured message could be replayed to a PC that restarted within the 15-minute window. |
| **Online only** | A PC receives messages only while it is on and someone is signed in. Messages to offline PCs aren't queued. |
| **Antivirus** | A hidden PowerShell script listening on the network can trigger some antivirus products. Allow `C:\ProgramData\OfficeMessenger` if needed. |

## Uninstall

- **Messenger:** run `tools\Uninstall-Office-Messenger.bat` on the PC. It removes the program, shortcuts and firewall rules (each user's message history is kept).
- **Network sharing:** turn it off in *Settings → Network & internet → Advanced network settings → Advanced sharing settings*.

## Troubleshooting

| Problem | Fix |
|---|---|
| *"Windows protected your PC"* | Click **More info → Run anyway** |
| A PC isn't in the Send list | Is Office Messenger running there (blue icon near the clock)? Is it on the same network? Click **Refresh**. |
| *"NOT delivered"* | That PC is off, asleep, or nobody is signed in |
| Two PCs can't message each other | They were set up with **different office keys**. Copy the same `messenger-key.txt` to both kits and re-run the setup. |
| Error about port 51515 | Another program uses that port. Change `$Port` in both `Setup-This-PC.bat` and `OfficeMessenger.ps1`. |

## License

[MIT](LICENSE) © 2026 Abishek M K
