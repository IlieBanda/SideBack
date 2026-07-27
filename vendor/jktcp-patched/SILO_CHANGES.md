# Silo's changes to `jktcp` 0.1.6

This directory is a vendored, modified copy of [`jktcp`](https://crates.io/crates/jktcp)
0.1.6 by Jackson Coxson (MIT-licensed — see `LICENSE.txt`), pulled in via a
`[patch.crates-io]` entry in `vendor/idevice/Cargo.toml` because `idevice`
depends on it for the userspace TCP stack it runs over the CoreDeviceProxy
tunnel.

Upstream: https://github.com/jkcoxson/jktcp

## What changed and why

`jktcp` as published always advertised a receive window of `65534 << 8` (≈
16.7 MB) and dropped out-of-order data with no ACK at all. In practice one
lost packet on the tunnel meant the receiver silently discarded everything
the sender had already put in flight above the gap — observed as hundreds
of dropped segments within a couple of milliseconds — and gave the sender no
signal to retransmit early, so recovery depended entirely on the sender's
own blind retransmission timeout. That was the root cause of multi-minute
silent stalls during real backups.

Three changes, in `src/adapter.rs`:

1. The window-scale exponent is now `SILO_JKTCP_WSCALE_BITS`-configurable
   (default 2, ≈256 KB) instead of a hardcoded 8, bounding how much a single
   loss can cost.
2. Out-of-order arrivals now trigger a re-ACK of the last good cumulative
   position (standard TCP receiver behavior), instead of a silent drop with
   no ACK — this lets a duplicate-ACK-aware sender fast-retransmit in
   roughly one RTT instead of waiting out a full RTO.
3. A real RTT sample is logged (`rtt=... hp=...`) on every ACK for a
   segment that was never retransmitted, so the window/RTT tradeoff can
   actually be measured instead of guessed.

Full diff: [`PATCHES/jktcp.patch`](../../PATCHES/jktcp.patch) at the repo root.

Every changed line is also marked inline with a `Silo patch:` comment.
