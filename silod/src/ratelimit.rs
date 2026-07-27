//! Per-IP throttling on failed authentication.
//!
//! `Session::run` already closes the socket after one bad token, which
//! stops brute-forcing *that* connection — but nothing stopped a peer from
//! just opening a new TCP connection per guess. This tracks recent
//! authentication failures per source IP and refuses new connections from
//! an IP that's over the limit, before the (relatively expensive) TLS
//! handshake even runs.

use std::collections::{HashMap, VecDeque};
use std::net::IpAddr;
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// Failures allowed from one IP within `WINDOW` before it's blocked.
const MAX_FAILURES: usize = 5;
const WINDOW: Duration = Duration::from_secs(60);

pub struct RateLimiter {
    failures: Mutex<HashMap<IpAddr, VecDeque<Instant>>>,
}

impl RateLimiter {
    pub fn new() -> Self {
        Self { failures: Mutex::new(HashMap::new()) }
    }

    /// True if this IP has hit the failure limit within the window. Also
    /// prunes that IP's expired entries, so a blocked IP isn't stuck
    /// forever once its failures age out.
    pub fn is_blocked(&self, ip: IpAddr) -> bool {
        let mut failures = self.failures.lock().unwrap();
        let Some(recent) = failures.get_mut(&ip) else { return false };
        prune(recent);
        if recent.is_empty() {
            failures.remove(&ip);
            return false;
        }
        recent.len() >= MAX_FAILURES
    }

    pub fn record_failure(&self, ip: IpAddr) {
        let mut failures = self.failures.lock().unwrap();
        let recent = failures.entry(ip).or_default();
        prune(recent);
        recent.push_back(Instant::now());
    }
}

fn prune(entries: &mut VecDeque<Instant>) {
    let cutoff = Instant::now() - WINDOW;
    while matches!(entries.front(), Some(t) if *t < cutoff) {
        entries.pop_front();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::{IpAddr, Ipv4Addr};

    fn ip() -> IpAddr {
        IpAddr::V4(Ipv4Addr::new(203, 0, 113, 1))
    }

    #[test]
    fn allows_up_to_the_limit() {
        let limiter = RateLimiter::new();
        for _ in 0..MAX_FAILURES - 1 {
            limiter.record_failure(ip());
        }
        assert!(!limiter.is_blocked(ip()), "should not block below the limit");
    }

    #[test]
    fn blocks_once_over_the_limit() {
        let limiter = RateLimiter::new();
        for _ in 0..MAX_FAILURES {
            limiter.record_failure(ip());
        }
        assert!(limiter.is_blocked(ip()), "should block at the limit");
    }

    #[test]
    fn different_ips_are_independent() {
        let limiter = RateLimiter::new();
        for _ in 0..MAX_FAILURES {
            limiter.record_failure(ip());
        }
        let other = IpAddr::V4(Ipv4Addr::new(203, 0, 113, 2));
        assert!(!limiter.is_blocked(other), "a different IP must not be affected");
    }
}
