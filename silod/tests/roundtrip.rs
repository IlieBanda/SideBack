//! End-to-end exercise of the silod protocol against real files on disk.
//!
//! Runs the real `Session` over an in-memory duplex pipe: no sockets, no
//! TLS, so these tests are deterministic and fast while still covering the
//! parts where bugs actually live — auth, integrity, resume, and the path
//! sandbox as seen from the wire.

use std::path::PathBuf;

use silod::protocol::{self, Request, Response, PROTOCOL_VERSION};
use silod::session::Session;
use sha2::Digest;
use tokio::io::DuplexStream;

fn sha256(bytes: &[u8]) -> [u8; 32] {
    sha2::Sha256::digest(bytes).into()
}

const TOKEN: &str = "test-token-at-least-16";

/// A temp dir that cleans up after itself even if a test fails.
struct TempRoot(PathBuf);

impl TempRoot {
    fn new(name: &str) -> Self {
        let path = std::env::temp_dir().join(format!(
            "silod-test-{name}-{}-{:?}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }
}

impl Drop for TempRoot {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Client side of a live session.
struct Client {
    stream: DuplexStream,
}

impl Client {
    fn spawn(root: PathBuf) -> Self {
        let (client, mut server) = tokio::io::duplex(1024 * 1024);
        tokio::spawn(async move {
            let session = Session::new(root, TOKEN.as_bytes().to_vec());
            let _ = session.run(&mut server, "test").await;
        });
        Self { stream: client }
    }

    async fn call(&mut self, request: Request) -> Response {
        protocol::write_frame(&mut self.stream, &request).await.unwrap();
        protocol::read_frame(&mut self.stream).await.unwrap()
    }

    async fn authenticate(&mut self) {
        let response = self
            .call(Request::Hello {
                version: PROTOCOL_VERSION,
                token: TOKEN.as_bytes().to_vec(),
            })
            .await;
        assert!(matches!(response, Response::Ok), "handshake failed: {response:?}");
    }

    /// Writes a whole file the way the delegate would: open, chunk, close.
    async fn put(&mut self, path: &str, contents: &[u8]) -> Response {
        let response = self
            .call(Request::CreateFileWrite { path: path.into(), truncate: true })
            .await;
        assert!(matches!(response, Response::Ok), "open failed: {response:?}");

        for chunk in contents.chunks(64 * 1024) {
            let response = self
                .call(Request::WriteChunk {
                    path: path.into(),
                    data: chunk.to_vec(),
                    hash: sha256(chunk),
                })
                .await;
            assert!(matches!(response, Response::Ok), "chunk failed: {response:?}");
        }

        self.call(Request::CloseFile {
            path: path.into(),
            hash: sha256(contents),
        })
        .await
    }
}

#[tokio::test]
async fn operations_are_refused_before_authentication() {
    let root = TempRoot::new("noauth");
    let mut client = Client::spawn(root.0.clone());

    let response = client.call(Request::Exists { path: "anything".into() }).await;
    assert!(
        matches!(response, Response::Error(ref message) if message.contains("not authenticated")),
        "unauthenticated request was not refused: {response:?}"
    );
}

#[tokio::test]
async fn wrong_token_is_rejected() {
    let root = TempRoot::new("badtoken");
    let mut client = Client::spawn(root.0.clone());

    let response = client
        .call(Request::Hello {
            version: PROTOCOL_VERSION,
            token: b"definitely-the-wrong-token".to_vec(),
        })
        .await;
    assert!(
        matches!(response, Response::Error(ref message) if message.contains("authentication")),
        "bad token was accepted: {response:?}"
    );
}

#[tokio::test]
async fn version_mismatch_is_rejected() {
    let root = TempRoot::new("badversion");
    let mut client = Client::spawn(root.0.clone());

    let response = client
        .call(Request::Hello {
            version: PROTOCOL_VERSION + 99,
            token: TOKEN.as_bytes().to_vec(),
        })
        .await;
    assert!(
        matches!(response, Response::Error(ref message) if message.contains("version")),
        "version mismatch was accepted: {response:?}"
    );
}

#[tokio::test]
async fn file_round_trips_with_correct_contents() {
    let root = TempRoot::new("roundtrip");
    let mut client = Client::spawn(root.0.clone());
    client.authenticate().await;

    // Larger than one chunk, so chunking is genuinely exercised.
    let contents: Vec<u8> = (0..200_000u32).map(|index| (index % 251) as u8).collect();

    let response = client.put("snapshot/ab/abcdef", &contents).await;
    assert!(matches!(response, Response::Ok), "close failed: {response:?}");

    let stored = std::fs::read(root.0.join("snapshot/ab/abcdef")).unwrap();
    assert_eq!(stored, contents, "stored bytes differ from what was sent");

    // And it reads back through the protocol.
    let response = client.call(Request::OpenFileRead { path: "snapshot/ab/abcdef".into() }).await;
    assert!(matches!(response, Response::Ok));

    let mut read_back = Vec::new();
    loop {
        match client
            .call(Request::ReadChunk { path: "snapshot/ab/abcdef".into(), max: 64 * 1024 })
            .await
        {
            Response::Data(data) => read_back.extend_from_slice(&data),
            Response::Eof => break,
            other => panic!("unexpected read response: {other:?}"),
        }
    }
    assert_eq!(read_back, contents, "read-back bytes differ");
}

#[tokio::test]
async fn corrupted_chunk_is_rejected() {
    let root = TempRoot::new("badchunk");
    let mut client = Client::spawn(root.0.clone());
    client.authenticate().await;

    client
        .call(Request::CreateFileWrite { path: "f".into(), truncate: true })
        .await;

    let response = client
        .call(Request::WriteChunk {
            path: "f".into(),
            data: b"actual bytes".to_vec(),
            hash: sha256(b"different bytes"),
        })
        .await;

    assert!(
        matches!(response, Response::Error(ref message) if message.contains("hash mismatch")),
        "corrupted chunk was accepted: {response:?}"
    );
}

#[tokio::test]
async fn file_with_wrong_final_hash_is_not_published() {
    let root = TempRoot::new("badfinal");
    let mut client = Client::spawn(root.0.clone());
    client.authenticate().await;

    client
        .call(Request::CreateFileWrite { path: "f".into(), truncate: true })
        .await;
    client
        .call(Request::WriteChunk {
            path: "f".into(),
            data: b"hello".to_vec(),
            hash: sha256(b"hello"),
        })
        .await;

    let response = client
        .call(Request::CloseFile {
            path: "f".into(),
            hash: sha256(b"something else entirely"),
        })
        .await;

    assert!(
        matches!(response, Response::Error(_)),
        "file with a bad whole-file hash was published: {response:?}"
    );
    assert!(
        !root.0.join("f").exists(),
        "a file that failed its integrity check must not appear under its real name"
    );
}

#[tokio::test]
async fn interrupted_transfer_resumes_without_corruption() {
    let root = TempRoot::new("resume");
    let mut client = Client::spawn(root.0.clone());
    client.authenticate().await;

    let first_half = vec![b'A'; 100_000];
    let second_half = vec![b'B'; 100_000];
    let whole: Vec<u8> = first_half.iter().chain(second_half.iter()).copied().collect();

    // Connection "drops" after the first half — no CloseFile.
    client
        .call(Request::CreateFileWrite { path: "big".into(), truncate: true })
        .await;
    client
        .call(Request::WriteChunk {
            path: "big".into(),
            data: first_half.clone(),
            hash: sha256(&first_half),
        })
        .await;

    // A fresh session, as would happen after a reconnect.
    let mut client = Client::spawn(root.0.clone());
    client.authenticate().await;

    let response = client.call(Request::Stat { path: "big".into() }).await;
    match response {
        Response::Stat { exists, size } => {
            assert!(!exists, "an unfinished transfer must not report as complete");
            assert_eq!(size, first_half.len() as u64, "wrong resume offset");
        }
        other => panic!("unexpected stat response: {other:?}"),
    }

    // Resume: append only what's missing.
    client
        .call(Request::CreateFileWrite { path: "big".into(), truncate: false })
        .await;
    client
        .call(Request::WriteChunk {
            path: "big".into(),
            data: second_half.clone(),
            hash: sha256(&second_half),
        })
        .await;
    let response = client
        .call(Request::CloseFile { path: "big".into(), hash: sha256(&whole) })
        .await;

    assert!(matches!(response, Response::Ok), "resumed close failed: {response:?}");
    assert_eq!(std::fs::read(root.0.join("big")).unwrap(), whole);
}

#[tokio::test]
async fn completed_file_reports_as_complete() {
    let root = TempRoot::new("statdone");
    let mut client = Client::spawn(root.0.clone());
    client.authenticate().await;

    client.put("done", b"payload").await;

    match client.call(Request::Stat { path: "done".into() }).await {
        Response::Stat { exists, size } => {
            assert!(exists);
            assert_eq!(size, 7);
        }
        other => panic!("unexpected stat response: {other:?}"),
    }
}

#[tokio::test]
async fn path_traversal_is_refused_over_the_wire() {
    let root = TempRoot::new("traversal");
    let mut client = Client::spawn(root.0.clone());
    client.authenticate().await;

    for hostile in ["../escaped", "a/../../escaped", "/etc/passwd"] {
        let response = client
            .call(Request::CreateFileWrite { path: hostile.into(), truncate: true })
            .await;
        assert!(
            matches!(response, Response::Error(_)),
            "sandbox escape accepted for {hostile:?}: {response:?}"
        );
    }

    assert!(
        !root.0.parent().unwrap().join("escaped").exists(),
        "a file was written outside the configured root"
    );
}

#[tokio::test]
async fn directory_and_metadata_operations_behave() {
    let root = TempRoot::new("meta");
    let mut client = Client::spawn(root.0.clone());
    client.authenticate().await;

    client.call(Request::CreateDirAll { path: "a/b/c".into() }).await;
    assert!(matches!(
        client.call(Request::IsDir { path: "a/b/c".into() }).await,
        Response::Bool(true)
    ));
    assert!(matches!(
        client.call(Request::Exists { path: "a/b/c".into() }).await,
        Response::Bool(true)
    ));

    client.put("a/file", b"contents").await;
    client
        .call(Request::Copy { src: "a/file".into(), dst: "a/copy".into() })
        .await;
    assert_eq!(std::fs::read(root.0.join("a/copy")).unwrap(), b"contents");

    client
        .call(Request::Rename { from: "a/copy".into(), to: "a/renamed".into() })
        .await;
    assert!(!root.0.join("a/copy").exists());
    assert!(root.0.join("a/renamed").exists());

    client.call(Request::Remove { path: "a/renamed".into() }).await;
    assert!(!root.0.join("a/renamed").exists());

    // Removing something absent is not an error — the delegate relies on it.
    assert!(matches!(
        client.call(Request::Remove { path: "never/existed".into() }).await,
        Response::Ok
    ));
}

