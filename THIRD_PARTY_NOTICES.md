# Third-party notices

Silo (this repository, `Silo/` and `silod/`) is licensed under the GPLv3 —
see `LICENSE`. It vendors two MIT-licensed dependencies with local
modifications:

## `vendor/idevice`

[`idevice`](https://github.com/jkcoxson/idevice) by Jackson Coxson, MIT
license (full text: `vendor/idevice/LICENSE.txt`). Vendored at commit
`a64b8867815b3da17b5c927531bdba877e8456ef` with modifications documented in
`vendor/idevice/SILO_CHANGES.md` and diffed in `PATCHES/idevice.patch`.

## `vendor/jktcp-patched`

[`jktcp`](https://github.com/jkcoxson/jktcp) 0.1.6 by Jackson Coxson, MIT
license (full text: `vendor/jktcp-patched/LICENSE.txt`). Vendored with
modifications documented in `vendor/jktcp-patched/SILO_CHANGES.md` and
diffed in `PATCHES/jktcp.patch`.

## Everything else

All other Rust dependencies (see `Cargo.lock` in `vendor/idevice/` and
`silod/`) are MIT, Apache-2.0, BSD, ISC, or similarly permissive, used
unmodified. `cbindgen` (MPL-2.0) is a build-time tool that generates
`idevice.h` from Rust source; it is not itself distributed as part of Silo.
