# Silo's changes to `idevice`

This directory is a vendored, modified copy of
[`idevice`](https://github.com/jkcoxson/idevice) by Jackson Coxson
(MIT-licensed — see `LICENSE.txt`), at commit
`a64b8867815b3da17b5c927531bdba877e8456ef`.

It was originally pulled in as a git submodule tracking upstream directly;
it is vendored as plain source instead so the repo builds from a single
clone and the patch below is visible without a separate fork to maintain.

Full diff: [`PATCHES/idevice.patch`](../../PATCHES/idevice.patch) at the
repo root.

## What changed and why

1. **`ffi/src/mobilebackup2.rs`, `idevice/src/services/mobilebackup2.rs`** —
   added a `list_dir` callback to `Mobilebackup2BackupDelegateFFI` and
   routed the `BackupDelegate::list_dir` implementation through it. As
   shipped, `list_dir` did `std::fs::read_dir` on the *local* filesystem of
   whatever process links this crate — for an iOS app whose backup storage
   is a remote server, that path never exists on-device, so the device was
   always told its backup directory was empty regardless of what the server
   actually held. This blocks Silo's resume: without it, the device can
   never recognize a file it already fully sent in a previous, interrupted
   run.
2. **`ffi/src/afc.rs`** — added a plain-`u64` `afc_file_lock` export
   (`AFC_LOCK_SHARED`/`AFC_LOCK_EXCLUSIVE`/`AFC_LOCK_UNLOCK` sentinel
   constants), used experimentally for an AFC sync-lock attempt that Silo
   ultimately doesn't use (see `SyncLock.swift` in the main app — it settled
   on notifications only, following the same pattern as
   [ByeTunes](https://github.com/EduAlexxis/ByeTunes)). Kept for anyone who
   wants to pick that experiment back up; not required for anything Silo
   currently does.
3. **`ffi/src/rsd.rs`** — minor additions supporting the above.
4. **`Cargo.toml`** (workspace root) — a `[patch.crates-io]` entry pointing
   `jktcp` at `../jktcp-patched`; see that directory's own `SILO_CHANGES.md`
   for why.

Every changed line is also marked inline with a `Silo patch:` comment where
it isn't self-evidently additive.
