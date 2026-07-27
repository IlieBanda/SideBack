# Silo

A self-hosted, on-device full backup of your iPhone to your own server — no
Mac, no iCloud, no third-party cloud. Silo runs on the phone itself and
streams a real `mobilebackup2` backup — the same protocol Finder uses — to
`silod`, a small server you run wherever you want.

## Status

> **EXPERIMENTAL — restore has never been tested. Do not use this as your
> only backup.**

This project is two days old (see the commit history). The backup path has been debugged
extensively against real hardware; nothing about restore has been verified
at all. Treat every backup Silo makes right now as unverified until it has
been read back by `idevicebackup2 info` (see below) and, eventually,
actually restored to a spare device.

### What works

- Establishing the on-device tunnel (RPPairing → CoreDeviceProxy → RSD) and
  opening `mobilebackup2` against the real device backup agent.
- Streaming a real backup to `silod` with per-file SHA-256 verification —
  an interrupted file never gets published as complete.
- Safe cancellation at any point.
- File-level resume: a file `silod` already holds and can verify by hash is
  recognized by the device and not re-sent after an interruption.
- Backup encryption, on by default, with a password-possession check before
  a run ever starts (see below — this part matters).

### What doesn't (yet)

- **Restore.** Not implemented, not tested, at all.
- **A completed full backup.** No run has gone from 0 to 100% yet.
- **Byte-level resume of a partial file.** `mobilebackup2` doesn't support
  it; only whole-file resume is possible.
- **An exact backup size estimate before starting.** The protocol doesn't
  expose one; Silo shows the device's used-storage as an upper bound
  instead.

## Requirements

- An unlocked iPhone with the screen on (or the background-keepalive
  toggle, which trades battery for tolerating the screen turning off).
- A running `LocalDevVPN`/`StosVPN`-style loopback tunnel already installed
  (Silo doesn't ship its own).
- A `silod` server reachable from the phone.
- Tested on iOS 27 betas. Untested on anything else — file an issue if you
  try.

## About the backup password

Silo turns on backup encryption by default and requires you to prove you
know the resulting password with a real round-trip to the device before a
backup ever starts — not just save-and-hope. Three things to understand
before you touch this:

1. **The password lives in this app's Keychain, on the phone you're
   backing up.** If the phone is lost, destroyed, or wiped before you've
   copied the password elsewhere, every encrypted backup made with it is
   permanently unreadable. Silo shows you the password in cleartext once,
   with a forced retype, when you first set it — write it down somewhere
   that isn't this phone.
2. **This is a device setting, not a per-app one.** The same password
   applies to Finder/iTunes and any other backup client until it's changed
   again.
3. **It cannot be reset normally.** Starting with iOS 11, the only way to
   remove a backup password you've forgotten is *Settings → General →
   Transfer or Reset iPhone → Reset → Reset All Settings* — which also
   wipes Wi-Fi passwords, Apple Pay cards, and every other setting, **and
   makes every previously-made encrypted backup of that phone permanently
   unreadable, including ones already sitting on your server.**

If you'd rather not deal with any of this, you can turn encryption off in
the app — but understand that an unencrypted backup silently omits
Keychain items, Health data, call history, and Safari history, even though
the run itself reports success.

## Verifying a backup without waiting for 100%

Don't wait for a full run to find out the format is wrong. Once a few GB
have transferred, pull `Manifest.plist` and `Status.plist` off `silod` and
run:

```bash
idevicebackup2 -s <udid> info
```

on a Mac/Linux box with [libimobiledevice](https://libimobiledevice.org/)
installed, pointed at a local copy of what `silod` has stored so far. If it
reads a valid manifest, the format is right and a long run is worth doing.

## Building

```bash
xcodegen generate   # regenerates Silo.xcodeproj from project.yml
```

The vendored Rust FFI library needs building once before Xcode can link it
— see `vendor/idevice/justfile` (`just apple-build` for the iOS device
slice is enough for a LiveContainer sideload; the full `just xcframework`
target also builds simulator/macOS/Catalyst slices if you need them).

## Acknowledgments

- [`idevice`](https://github.com/jkcoxson/idevice) (Jackson Coxson) — the
  Rust `mobilebackup2`/RSD/CoreDeviceProxy protocol implementation
  everything here is built on.
- [SideStore](https://sidestore.io/) / [LocalDevVPN](https://github.com/SideStore/LocalDevVPN) —
  the loopback tunnel trick this project reuses wholesale.
- [ByeTunes](https://github.com/EduAlexxis/ByeTunes) — an independent app on
  the same `idevice` stack, used as an architecture/interface reference and
  as evidence for simplifying Silo's iTunes-sync-lock handling down to
  notifications only.

## License

GPLv3 — see `LICENSE`. This project vendors two MIT-licensed dependencies
(`idevice`, `jktcp`) with local modifications; see `THIRD_PARTY_NOTICES.md`.
