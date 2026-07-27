//! Wire protocol between Silo (iOS) and silod.
//!
//! Deliberately shaped to mirror `mobilebackup2`'s `BackupDelegate` trait
//! one-to-one: the delegate needs a small remote filesystem, so that is
//! exactly what this protocol exposes — no more, no less. Anything the
//! delegate can't ask for is not in the protocol surface.
//!
//! Framing: `u32` big-endian payload length, then a bincode-encoded
//! `Request`/`Response`.

use serde::{Deserialize, Serialize};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

pub const PROTOCOL_VERSION: u32 = 1;

/// Hard cap on a single frame. Chunks are sent well below this; the cap
/// exists so a malformed or hostile length prefix can't make the peer
/// allocate unbounded memory.
pub const MAX_FRAME_BYTES: u32 = 16 * 1024 * 1024;

/// Payload size the client should aim for per `WriteChunk`. Small enough
/// to keep resume granularity useful, large enough to amortise framing.
pub const TARGET_CHUNK_BYTES: usize = 1024 * 1024;

#[derive(Debug, Serialize, Deserialize)]
pub enum Request {
    /// Must be the first message on a connection.
    Hello { version: u32, token: Vec<u8> },

    // --- BackupDelegate surface ---
    CreateDirAll { path: String },
    /// `truncate: false` appends to an existing partial transfer — pair it
    /// with `Stat` to learn the resume offset. `true` starts over.
    CreateFileWrite { path: String, truncate: bool },
    /// `hash` is SHA-256 of `data`; the server rejects mismatches rather
    /// than silently storing corrupted bytes.
    WriteChunk { path: String, data: Vec<u8>, hash: [u8; 32] },
    /// `hash` is SHA-256 of the whole file as the client wrote it. The
    /// server verifies before the file is atomically published.
    CloseFile { path: String, hash: [u8; 32] },
    OpenFileRead { path: String },
    ReadChunk { path: String, max: u32 },
    CloseRead { path: String },
    Exists { path: String },
    IsDir { path: String },
    Remove { path: String },
    Rename { from: String, to: String },
    Copy { src: String, dst: String },

    /// How much of `path` the server already holds, so an interrupted
    /// transfer can resume instead of restarting from zero.
    ///
    /// - `exists: true,  size: N` — complete file of N bytes, skip it
    /// - `exists: false, size: N` — partial transfer, resume at offset N
    /// - `exists: false, size: 0` — nothing stored yet
    Stat { path: String },

    /// Entries directly inside `path`. mobilebackup2 asks for this when it
    /// wants to know what an existing backup already contains, so an empty
    /// answer tells the device the backup is empty — it must reflect what
    /// the server actually holds, not a guess.
    ListDir { path: String },
}

/// One entry of a `ListDir` result. In-progress `.silo-part` files are not
/// reported: to the device they do not exist yet.
#[derive(Debug, Serialize, Deserialize)]
pub struct DirEntry {
    pub name: String,
    pub is_dir: bool,
    pub size: u64,
    /// Seconds since the Unix epoch, or `None` when unavailable.
    pub modified: Option<i64>,
}

#[derive(Debug, Serialize, Deserialize)]
pub enum Response {
    Ok,
    Bool(bool),
    Stat { exists: bool, size: u64 },
    Listing(Vec<DirEntry>),
    Data(Vec<u8>),
    /// End of file reached during `ReadChunk`.
    Eof,
    Error(String),
}

#[derive(Debug, thiserror::Error)]
pub enum ProtocolError {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("frame of {0} bytes exceeds the {MAX_FRAME_BYTES} byte limit")]
    FrameTooLarge(u32),
    #[error("malformed frame: {0}")]
    Malformed(#[from] bincode::Error),
}

pub async fn write_frame<W, T>(writer: &mut W, value: &T) -> Result<(), ProtocolError>
where
    W: AsyncWrite + Unpin,
    T: Serialize,
{
    let payload = bincode::serialize(value)?;
    let len = u32::try_from(payload.len()).map_err(|_| ProtocolError::FrameTooLarge(u32::MAX))?;
    if len > MAX_FRAME_BYTES {
        return Err(ProtocolError::FrameTooLarge(len));
    }
    writer.write_all(&len.to_be_bytes()).await?;
    writer.write_all(&payload).await?;
    writer.flush().await?;
    Ok(())
}

pub async fn read_frame<R, T>(reader: &mut R) -> Result<T, ProtocolError>
where
    R: AsyncRead + Unpin,
    T: for<'de> Deserialize<'de>,
{
    let mut len_bytes = [0u8; 4];
    reader.read_exact(&mut len_bytes).await?;
    let len = u32::from_be_bytes(len_bytes);
    if len > MAX_FRAME_BYTES {
        return Err(ProtocolError::FrameTooLarge(len));
    }
    let mut payload = vec![0u8; len as usize];
    reader.read_exact(&mut payload).await?;
    Ok(bincode::deserialize(&payload)?)
}

#[cfg(test)]
mod wire_format_tests {
    use super::*;

    /// Pins the exact bytes on the wire. The Swift client hand-encodes this
    /// format, so if bincode's representation ever shifts, this fails here
    /// rather than as a mysterious protocol error on a phone.
    #[test]
    fn hello_encoding_is_stable() {
        let bytes = bincode::serialize(&Request::Hello {
            version: 1,
            token: b"abc".to_vec(),
        })
        .unwrap();
        assert_eq!(
            bytes,
            vec![
                0, 0, 0, 0, // variant index 0, u32 LE
                1, 0, 0, 0, // version 1, u32 LE
                3, 0, 0, 0, 0, 0, 0, 0, // token length 3, u64 LE
                b'a', b'b', b'c',
            ],
            "Hello wire format changed"
        );
    }

    #[test]
    fn exists_encoding_is_stable() {
        let bytes = bincode::serialize(&Request::Exists { path: "hi".into() }).unwrap();
        assert_eq!(
            bytes,
            vec![
                8, 0, 0, 0, // variant index of Exists (0-based, in declaration order)
                2, 0, 0, 0, 0, 0, 0, 0, // string length 2
                b'h', b'i',
            ],
            "Exists wire format changed"
        );
    }

    #[test]
    fn fixed_array_has_no_length_prefix() {
        let bytes = bincode::serialize(&Request::CloseFile {
            path: "a".into(),
            hash: [7u8; 32],
        })
        .unwrap();
        // variant(4) + len(8) + "a"(1) = 13 bytes of header, then 32 raw.
        assert_eq!(bytes.len(), 13 + 32);
        assert_eq!(&bytes[13..], &[7u8; 32]);
    }

    /// Cross-checked byte-for-byte against the hand-written Swift encoder
    /// (`SilodWire.swift`) via a standalone macOS test client that talks to
    /// a real running `silod` — this exact hex string is what both sides
    /// independently produced.
    #[test]
    fn write_chunk_encoding_matches_the_swift_client() {
        let bytes = bincode::serialize(&Request::WriteChunk {
            path: "a".into(),
            data: vec![1, 2, 3],
            hash: [7u8; 32],
        })
        .unwrap();
        let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(
            hex,
            "0300000001000000000000006103000000000000000102030707070707070707070707070707070707070707070707070707070707070707"
        );
    }

    #[test]
    fn response_variants_are_stable() {
        assert_eq!(bincode::serialize(&Response::Ok).unwrap(), vec![0, 0, 0, 0]);
        assert_eq!(
            bincode::serialize(&Response::Bool(true)).unwrap(),
            vec![1, 0, 0, 0, 1]
        );
    }
}
