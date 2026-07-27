# Security policy

Silo moves a full, potentially unencrypted copy of your phone's data to a
server you control, and separately manages a backup-encryption password
whose loss makes that data permanently unreadable. Both the transport
(`silod`'s TLS) and the password handling are exactly the kind of thing
worth a private report instead of a public issue.

## Reporting a vulnerability

Please **do not** open a public GitHub issue for:

- Anything that could let someone other than the phone's owner read or
  write backup data on `silod` (auth bypass, TLS pinning issues, path
  traversal in file operations, etc).
- Anything involving the backup-encryption password (weak storage, leakage
  to logs, incorrect verification logic).
- Memory-safety issues at the Swift/Rust FFI boundary that could be
  triggered by a malicious or malformed device response.

Instead, open a [private security advisory](../../security/advisories/new)
on this repository, or email the address in the repository owner's GitHub
profile if that isn't available to you. Include:

- What you found and why it's exploitable.
- Steps to reproduce, if you have them.
- Whether you're aware of it being exploited.

There's no bug bounty — this is a hobby project — but reports will be
credited (with permission) once a fix ships.

## Scope

In scope: `Silo/` (the iOS app), `silod/` (the server), and Silo's own
modifications to `vendor/idevice` and `vendor/jktcp-patched` (see
`THIRD_PARTY_NOTICES.md`). Bugs in the unmodified portions of those
vendored dependencies should go to their own upstream repositories instead.
