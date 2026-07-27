# Contributing

SideBack is early and the highest-value contributions right now are
reports, not features:

- **Real-device test results.** iOS version, backup size, whether it
  completed, and the protocol log (SideBack → Backup → "idevice protocol
  (live)") for anything that stalled or failed. This is worth more than any code change
  right now — restore hasn't been tested at all, and the backup path has
  only run on one device so far.
- **`idevicebackup2 info` output** against a partial or complete backup
  pulled from `silod` — see the README section on verifying without
  waiting for 100%.

## Code changes

- Match the existing comment style: comments explain *why*, not *what* —
  a hidden constraint, a workaround for a specific device behavior, a
  measured number. Don't add a comment that just restates the code.
- If you touch the Swift/Rust FFI boundary (anything under
  `vendor/idevice/ffi` or the `Mobilebackup2BackupDelegateFFI` struct),
  read `vendor/idevice/SILO_CHANGES.md` first — this boundary has already
  caused one real crash in this project (a `#[repr(u64)]` enum that
  cbindgen and Swift disagreed about the layout of). Struct field order
  must match exactly between the Rust definition and every copy of the C
  header, and the compiled `.a` in `swift/IDevice.xcframework` must be
  rebuilt and re-copied after *any* change to `vendor/idevice` or
  `vendor/jktcp-patched` — Xcode will happily link a stale `.a` against a
  new header without complaint.
- If you modify `vendor/idevice` or `vendor/jktcp-patched`, update the
  corresponding `SILO_CHANGES.md` and regenerate `PATCHES/*.patch` — this
  is a license requirement (both are MIT), not just documentation.
- Never commit real UDIDs, pairing files, `.mobiledevice` files, private
  keys, or `silod` tokens — check `.gitignore` covers what you're adding
  before committing test artifacts.

## Testing changes

Real-device testing is the only testing that matters here — `mobilebackup2`
and the RSD tunnel don't exist on the Simulator (see the README status
section). If you can't test on real hardware, say so explicitly in the PR
rather than claiming it works.
