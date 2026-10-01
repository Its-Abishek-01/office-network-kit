OFFICE NETWORK KIT
==================
Sets up Windows PCs in an office so they can see each other on the network
(file and printer sharing) and send pop-up messages to each other
(Office Messenger). No server, no internet, no accounts needed.

REQUIREMENTS
  - Windows 10 or 11, PCs connected to the same office network (cable or Wi-Fi)
  - An administrator account on each PC (the setup asks for permission)

ON EACH OFFICE PC
  1. Copy this folder to a pendrive and plug it in.
  2. Double-click  Setup-This-PC.bat  and click Yes.
  3. Confirm it is connected to your OFFICE network, then answer the questions.
     It asks before each part:
       1. Network sharing  - marks the office network as Private and turns on
                             Network Discovery + File and Printer Sharing
                             (Private networks only - never on public Wi-Fi)
                             Optional: give the PC a clear name (e.g. ACCOUNTS-01)
       2. Office Messenger - installs the pop-up messenger
  4. If you gave the PC a new name, restart it when convenient.

  Safe to run again on the same PC (for example to update the messenger).
  Every PC you set up is recorded in office-pcs.csv.

CHECK THE WHOLE OFFICE
  Double-click  tools\Check-Office.bat  (no admin needed, changes nothing).
  It lists every PC: messenger running + version, file sharing on/off.

UPDATING TO A NEW VERSION
  Copy your messenger\messenger-key.txt into the new kit first, then run
  Setup-This-PC.bat on each PC: n to network sharing, Y to Office Messenger.
  No need to update all PCs at once - old and new versions work together.
  Messages are encrypted when BOTH PCs run v1.2 or later.

THE OFFICE KEY (messenger-key.txt)
  - The FIRST time you install the messenger, the setup creates a new office key
    in the messenger folder. Use the SAME kit (same key) for every PC in the office.
  - PCs with different keys cannot message each other.
  - Keep the key private: anyone with it can send pop-ups to your office PCs.

USING OFFICE MESSENGER
  - Starts automatically with Windows. Blue chat icon near the clock.
  - Click the icon or the Desktop shortcut -> tick people -> type -> Send.
  - Quick messages: Come to my desk, Call me, Meeting now, Check your email.
  - Urgent = red pop-up with alert sound.
  - The person can reply with one click (Coming now / Give me 5 min / OK, seen)
    or type a reply.
  - Right-click the icon: Message history, Change my name, Exit.
  - A PC only receives messages while it is switched on and someone is signed in.

SHARING THIS KIT WITH SOMEONE ELSE
  Delete these two files from the copy first:
    messenger\messenger-key.txt   (your office key)
    office-pcs.csv                (your list of PCs)
  Their first setup will then create their own key.

REMOVING
  tools\Uninstall-Office-Messenger.bat  removes the messenger from a PC.
  Network sharing can be turned off in Settings > Network & internet >
  Advanced network settings > Advanced sharing settings.

IF SOMETHING IS BLOCKED
  - "Windows protected your PC": click More info -> Run anyway.
  - Antivirus warning: allow C:\ProgramData\OfficeMessenger in that antivirus.
  - Messenger shows "NOT delivered": that PC is off, asleep, or no one is signed in.
