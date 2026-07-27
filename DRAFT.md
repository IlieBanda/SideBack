# TimeToLoad (TTL) — original draft

> Historical planning note from before the project had a working backup
> path. Kept for context, not maintained — see `README.md` for current
> status. The phase list below stops matching reality after Phase 1;
> everything past that (network `BackupDelegate`, `silod`, encryption,
> resume) has since been built and looks different from what's sketched
> here.

## The idea in one sentence
A full, encrypted, "Time Machine"-like iPhone backup straight to your own
server — no Mac, no iCloud, no separate box. You're in another country, the
app backed up to your server "just in case," and if something happens, you
restore from that same backup.

## Why nobody else has done this
- iCloud — not your server, a paid limit, no full backup without paying more.
- iTunes/Finder — needs a Mac physically nearby.
- iOS Backup Machine (the closest existing thing) — also self-hosted and
  cloud-free, but needs a separate physical USB box. Doesn't work "from
  another country," not fully on-device.
- BackupFlow and similar — photos/video only, not a full system image.

## How it works technically
```
Your iPhone                              Your Linux server
  └─ Silo.app (SwiftUI, native)             └─ silod (Rust, cross-platform daemon)
       ├─ Loopback VPN (LocalDevVPN/StosVPN,     ├─ TCP+TLS, its own protocol (not WebDAV/SFTP)
       │     not bundled with Silo — external)   ├─ resumable chunked transfer
       ├─ mobilebackup2 client (Rust, idevice,   ├─ integrity checking (per-chunk hashes)
       │     backup_from_path/restore_from_path) └─ versioned restore points
       └─ NetworkBackupDelegate  ───── network ─────►
             (a custom BackupDelegate, streams        (no NAS/WebDAV/SFTP —
              instead of FsBackupDelegate)              a custom protocol on both ends)
```

Key finding: the `idevice` library already implements Apple's entire
protocol (backup AND restore), and is specifically designed around an
abstract `BackupDelegate` — not tied to local disk. The hardest part
(reverse-engineering Apple's protocol) is already done by the open-source
community.

Restore runs the same path in reverse — no DFU/Recovery Mode needed, the
device just needs to be on and unlocked, working over the same loopback.

**Server decision (settled):** no Mac companion (macOS can already back up
via Finder) and no generic WebDAV/SFTP (unreliable — depends on the
specific NAS/server implementation). Instead: a lightweight, cross-platform
Rust daemon, `silod`, running on any Linux server the user owns, with its
own simple, reliable protocol (a TLS channel, integrity-checked chunks,
resume on interruption). Priority: maximum transfer reliability and a
native look/feel on the iOS client side.

## Phases

**Phase 0 — Proof of concept (no iOS, protocol only)**
Exercise `idevice::mobilebackup2` by hand from a computer over USB against
a test device (not from the iOS app) — confirm backup_from_path/
restore_from_path actually work on current iOS, not just in theory.

**Phase 1 — On-device access — DONE, VERIFIED ON HARDWARE**
`idevice-ffi` built for `aarch64-apple-ios`/`aarch64-apple-ios-sim`,
embedded in Silo as a `.xcframework`. The app, running on a real iPhone
(iOS 27 beta, launched via LiveContainer, tunneling through
LocalDevVPN/StosVPN), successfully:
- establishes an authenticated tunnel: TCP **:49152** → RPPairing →
  CoreDeviceProxy → RSD handshake;
- retrieves the device UUID and RSD protocol version (7);
- enumerates **85** services the device advertises over RSD;
- **opens a channel to `mobilebackup2`** via `mobilebackup2_connect_rsd` —
  the exact service iTunes/Finder use for a full backup.

The project's core hypothesis ("a full backup without a computer is
possible") is confirmed by working code on real hardware, not just theory.

Pitfalls not to repeat:
- Port **49152**, not 62078. 62078 is the classic lockdownd port, and this
  protocol resets the connection there.
- StosVPN/LocalDevVPN isn't a proxy service, it's a pure IP-packet
  rewriter (10.7.0.0 ↔ 10.7.0.1). The device itself always answers.
- The pairing file is the modern `RpPairingFile` format
  (`identifier`/`private_key`/`public_key`/`alt_irk`), parsed via
  `rp_pairing_file_from_bytes`. This is NOT the classic `PairingFile`
  (`DeviceCertificate`/`HostPrivateKey`/...) that `idevice_start_session`
  expects.
- Compute the gateway address as the subnet's first address
  (address & netmask | 1), not via `ifa_dstaddr` — that returns the
  device's own address instead.

**Phase 2 — A network `BackupDelegate` plus a custom `silod` server**
Write a `BackupDelegate` implementation that sends/reads files over a
custom TLS protocol instead of `tokio::fs`. In parallel, a minimal Rust
(tokio) `silod` running on the user's Linux server: accepts the stream,
writes chunks to disk with hash verification, supports resuming an
interrupted transfer, and stores dated backup versions.

**Phase 3 — Restore (carefully)**
Test on a spare/test device only at first — restore is a potentially
destructive operation if it's interrupted partway through.

**Phase 4 — UI and polish**
A native SwiftUI interface: backup scheduling, status, progress,
encryption password management, a list of restore points (versioning — one
server-side folder per date).

## Open risks / what to check first
- Whether Apple grants NEPacketTunnelProvider entitlements in this
  context (already settled by precedent from StikDebug/SideStore — we
  reuse their approach).
- Whether loopback access to mobilebackup2 behaves like it does for other
  lockdown services (needs to be checked by hand in Phase 0/1 — not yet
  confirmed by anyone specifically for this service).
- Backup encryption: the password must be stored only with the user
  (Keychain on the phone), never sent to the server in the clear.
- Restore — test-device only, until there's real confidence in it.

## Name
**Silo** (working title). Formerly TimeToLoad / TTL.

Icon: `Icon/silo-icon.svg` (master) → `Icon/AppIcon.appiconset/` (ready to
drag into Xcode).
Palette: graphite `#3D3527`, cream `#F3EEE3`, terracotta accent `#D97757`.
