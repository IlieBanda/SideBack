//! Per-connection handling: authenticate once, then serve filesystem
//! operations until the peer goes away.

use std::path::PathBuf;

use sha2::Digest;
use subtle::ConstantTimeEq;
use tokio::io::{AsyncRead, AsyncWrite};
use tracing::{debug, info, warn};

use crate::protocol::{self, ProtocolError, Request, Response, PROTOCOL_VERSION};
use crate::storage::Storage;

pub struct Session {
    storage: Storage,
    token: Vec<u8>,
    authenticated: bool,
}

impl Session {
    pub fn new(root: PathBuf, token: Vec<u8>) -> Self {
        Self { storage: Storage::new(root), token, authenticated: false }
    }

    pub async fn run<S>(mut self, stream: &mut S, peer: &str) -> Result<(), ProtocolError>
    where
        S: AsyncRead + AsyncWrite + Unpin,
    {
        loop {
            let request: Request = match protocol::read_frame(stream).await {
                Ok(request) => request,
                Err(ProtocolError::Io(error))
                    if error.kind() == std::io::ErrorKind::UnexpectedEof =>
                {
                    debug!(%peer, "peer closed the connection");
                    return Ok(());
                }
                Err(error) => return Err(error),
            };

            let response = self.handle(request, peer).await;
            let fatal = matches!(response, Response::Error(_)) && !self.authenticated;
            protocol::write_frame(stream, &response).await?;

            // A failed handshake ends the connection rather than allowing
            // unlimited token guesses on one socket.
            if fatal {
                warn!(%peer, "closing connection after failed handshake");
                return Ok(());
            }
        }
    }

    async fn handle(&mut self, request: Request, peer: &str) -> Response {
        if let Request::Hello { version, token } = &request {
            if *version != PROTOCOL_VERSION {
                return Response::Error(format!(
                    "protocol version mismatch: server speaks {PROTOCOL_VERSION}, client sent {version}"
                ));
            }
            // Constant-time so a wrong token leaks nothing through timing.
            let matches: bool = token.as_slice().ct_eq(self.token.as_slice()).into();
            if !matches {
                warn!(%peer, "rejected: bad token");
                return Response::Error("authentication failed".into());
            }
            self.authenticated = true;
            info!(%peer, "authenticated");
            return Response::Ok;
        }

        if !self.authenticated {
            return Response::Error("not authenticated: send Hello first".into());
        }

        match self.dispatch(request).await {
            Ok(response) => response,
            Err(error) => Response::Error(error.to_string()),
        }
    }

    async fn dispatch(&mut self, request: Request) -> Result<Response, crate::storage::StorageError> {
        Ok(match request {
            Request::Hello { .. } => Response::Error("already authenticated".into()),

            Request::CreateDirAll { path } => {
                self.storage.create_dir_all(&path).await?;
                Response::Ok
            }
            Request::CreateFileWrite { path, truncate } => {
                self.storage.create_file_write(&path, truncate).await?;
                Response::Ok
            }
            Request::WriteChunk { path, data, hash } => {
                // Verify before touching the disk: a corrupted chunk should
                // never reach storage, even transiently.
                let actual: [u8; 32] = sha2::Sha256::digest(&data).into();
                if actual != hash {
                    return Ok(Response::Error(format!("chunk hash mismatch for {path:?}")));
                }
                self.storage.write_chunk(&path, &data).await?;
                Response::Ok
            }
            Request::CloseFile { path, hash } => {
                self.storage.close_file(&path, &hash).await?;
                Response::Ok
            }
            Request::OpenFileRead { path } => {
                self.storage.open_file_read(&path).await?;
                Response::Ok
            }
            Request::ReadChunk { path, max } => {
                let max = (max as usize).min(protocol::TARGET_CHUNK_BYTES);
                match self.storage.read_chunk(&path, max).await? {
                    Some(data) => Response::Data(data),
                    None => Response::Eof,
                }
            }
            Request::CloseRead { path } => {
                self.storage.close_read(&path);
                Response::Ok
            }
            Request::Exists { path } => Response::Bool(self.storage.exists(&path).await?),
            Request::IsDir { path } => Response::Bool(self.storage.is_dir(&path).await?),
            Request::Remove { path } => {
                self.storage.remove(&path).await?;
                Response::Ok
            }
            Request::Rename { from, to } => {
                self.storage.rename(&from, &to).await?;
                Response::Ok
            }
            Request::Copy { src, dst } => {
                self.storage.copy(&src, &dst).await?;
                Response::Ok
            }
            Request::Stat { path } => {
                let (exists, size) = self.storage.stat(&path).await?;
                Response::Stat { exists, size }
            }
            Request::ListDir { path } => Response::Listing(self.storage.list_dir(&path).await?),
        })
    }
}
