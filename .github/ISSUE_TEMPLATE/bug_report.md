---
name: Bug report
about: Something didn't work — backup, tunnel, or encryption
title: ""
labels: bug
assignees: ""
---

**Device & iOS version**
e.g. iPhone 15 Pro, iOS 26.0

**Backup size (roughly)**
Used storage on the device, from SideBack's "Estimate backup size" if you ran it.

**What happened**
Stalled / crashed / finished but looked wrong / other — be specific about
where in the run (right at start, mid-transfer, near the end).

**Protocol log**
Paste the relevant tail of "idevice protocol (live)" from the Backup
screen — the `DebugLog` entries with real timestamps are what actually pin
down what happened. Redact nothing except the pairing file contents
themselves; UDIDs and IPs on the loopback tunnel (`10.7.0.x`) aren't
sensitive.

**Encryption**
On or off? If on, did the password-verification step run, and did it pass?

**Anything unusual about the setup**
Screen lock behavior, background-keepalive toggle state, sync-lock toggle
state, whether this was a fresh install or an upgrade from a previous
SideBack build.
