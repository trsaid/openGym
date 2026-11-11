# The Apple Watch app with a free Apple ID

The `Personal IPA` workflow builds an unsigned IPA of the iPhone app with the watch app inside it.
Signed with a paid developer account, the watch app installs like any other. Signed with a free
Apple ID, it does not:

- Sideloadly signs watch apps only for paid accounts (its changelog, version 0.71.0).
- Impactor signs it, but the watch then refuses it when it comes through the iPhone's Watch app:
  "This app cannot be installed because its integrity could not be verified". watchOS does not take
  an app with a free profile from that route, and the watch is not on the profile anyway.

What works instead: register the watch on the Apple ID, sign with Impactor's command-line tool,
and install the watch app straight onto the watch as a developer app, the way Xcode does.
`scripts/ios/watch-sideload.py` does the parts that talk to the watch. It runs on Windows, Linux
and macOS; no Mac or Xcode is needed.

This was put together from the tools' sources and one report of the same steps working
([carcaret/gym-companion-ios#2](https://github.com/carcaret/gym-companion-ios/issues/2)). Treat it
as a recipe to try, and correct this page when a step turns out different.

## What you need

- The iPhone on a USB cable, unlocked, with Developer Mode on (sideloaded apps need it anyway). The
  watch on the wrist, unlocked, near the iPhone.
- On Windows: iTunes from apple.com (not the Microsoft Store app), for Apple's device drivers.
- Python 3.10 or later, then `python -m pip install -U pymobiledevice3`.
- `plumesign`, Impactor's command-line tool: `plumesign-windows-x86_64.exe` from
  [Impactor's releases](https://github.com/khcrysalis/Impactor/releases/latest) (or the macOS or
  Linux build).
- `watch-sideload.py` from this folder, and the IPA (artifact `opengym-personal-ipa`).

The watch's complications are left out of the personal IPA (see the top of `personal-ipa.yml`).

## Once

```bash
python watch-sideload.py watch                     # prints the watch's UDID
plumesign account login -u you@example.com          # asks for the password and the 2FA code
plumesign account register-device -u <watch UDID> -n "Apple Watch"
python watch-sideload.py reveal                    # shows the Developer Mode switch on the watch
```

On the watch: Settings, Privacy & Security, Developer Mode, on. The watch restarts and asks to
confirm.

## Every install, and every 7 days

```bash
plumesign sign --apple-id -p openGym-personal-xxxxxxx.ipa -o openGym-signed.ipa --register-and-install
python watch-sideload.py install openGym-signed.ipa
```

The first line signs the IPA with the account (the profile now holds the iPhone and the watch),
installs the iPhone app and keeps the signed IPA. The second puts its watch app on the watch.

A free account's apps stop opening after 7 days, and so do its device registrations: run both lines
again then. If `register-device` answers that the device already exists, it is still registered.

## When it goes wrong

- `watch` finds no watch: the watch is asleep or too far. Wake it and try again.
- The USB route does not offer the companion proxy on every iOS version; the script then builds the
  iOS 17 tunnel itself (`--via tunnel` to force it, `--via usb` to forbid it).
- `install` fails with a provisioning error: the watch is not on the profile. Check
  `plumesign account devices`, register it, sign again.
- A free Apple ID can create 10 app IDs a week. Each new signing of openGym uses two (the iPhone app
  and the watch app); re-signing the same app does not use new ones.
