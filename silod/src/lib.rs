//! silod — the destination end of Silo.
//!
//! Exposed as a library so the protocol, storage sandbox, and session
//! logic can be exercised by integration tests without going through a
//! socket.

pub mod protocol;
pub mod ratelimit;
pub mod session;
pub mod storage;
