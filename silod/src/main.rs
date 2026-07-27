//! silod — the destination end of Silo.
//!
//! Runs on the user's own Linux server and accepts an authenticated TLS
//! connection from Silo on the phone, exposing exactly the filesystem
//! operations `mobilebackup2`'s delegate needs. Nothing else is exposed.


use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{bail, Context, Result};
use clap::Parser;
use rustls::pki_types::pem::PemObject;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use sha2::{Digest, Sha256};
use tokio::net::TcpListener;
use tokio_rustls::TlsAcceptor;
use tracing::{error, info, warn};

use silod::session::Session;

#[derive(Parser, Debug)]
#[command(name = "silod", about = "Self-hosted backup destination for Silo")]
struct Args {
    /// Directory backups are written into. Nothing is ever written outside it.
    #[arg(long)]
    root: PathBuf,

    /// Address to listen on.
    #[arg(long, default_value = "0.0.0.0:9143")]
    listen: SocketAddr,

    /// File holding the shared secret. A file rather than a flag so the
    /// token never shows up in `ps` output or shell history.
    #[arg(long)]
    token_file: PathBuf,

    /// TLS certificate (PEM). If omitted, a self-signed one is generated
    /// in memory each start and its fingerprint printed for pinning.
    #[arg(long, requires = "key")]
    cert: Option<PathBuf>,

    /// TLS private key (PEM).
    #[arg(long, requires = "cert")]
    key: Option<PathBuf>,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "silod=info".into()),
        )
        .init();

    rustls::crypto::ring::default_provider()
        .install_default()
        .map_err(|_| anyhow::anyhow!("failed to install the ring crypto provider"))?;

    let args = Args::parse();

    let token = load_token(&args.token_file)?;
    tokio::fs::create_dir_all(&args.root)
        .await
        .with_context(|| format!("creating backup root {:?}", args.root))?;
    let root = tokio::fs::canonicalize(&args.root)
        .await
        .with_context(|| format!("resolving backup root {:?}", args.root))?;

    let tls_config = build_tls_config(args.cert.as_deref(), args.key.as_deref())?;
    let acceptor = TlsAcceptor::from(Arc::new(tls_config));

    let listener = TcpListener::bind(args.listen)
        .await
        .with_context(|| format!("binding {}", args.listen))?;

    info!(root = ?root, listen = %args.listen, "silod ready");

    loop {
        let (stream, peer) = match listener.accept().await {
            Ok(accepted) => accepted,
            Err(error) => {
                error!(%error, "accept failed");
                continue;
            }
        };

        let acceptor = acceptor.clone();
        let root = root.clone();
        let token = token.clone();

        // One task per connection; a misbehaving peer cannot stall others.
        tokio::spawn(async move {
            let peer = peer.to_string();
            let mut stream = match acceptor.accept(stream).await {
                Ok(stream) => stream,
                Err(error) => {
                    warn!(%peer, %error, "TLS handshake failed");
                    return;
                }
            };

            let session = Session::new(root, token);
            if let Err(error) = session.run(&mut stream, &peer).await {
                warn!(%peer, %error, "session ended with an error");
            }
        });
    }
}

fn load_token(path: &PathBuf) -> Result<Vec<u8>> {
    let raw = std::fs::read_to_string(path)
        .with_context(|| format!("reading token file {path:?}"))?;
    let token = raw.trim();
    if token.len() < 16 {
        bail!("token in {path:?} is too short — use at least 16 characters");
    }
    Ok(token.as_bytes().to_vec())
}

fn build_tls_config(
    cert_path: Option<&std::path::Path>,
    key_path: Option<&std::path::Path>,
) -> Result<rustls::ServerConfig> {
    let (certs, key) = match (cert_path, key_path) {
        (Some(cert_path), Some(key_path)) => load_pem_pair(cert_path, key_path)?,
        _ => generate_self_signed()?,
    };

    let fingerprint = certs
        .first()
        .map(|cert| {
            let digest = Sha256::digest(cert.as_ref());
            digest
                .iter()
                .map(|byte| format!("{byte:02X}"))
                .collect::<Vec<_>>()
                .join(":")
        })
        .unwrap_or_default();
    info!(sha256 = %fingerprint, "TLS certificate fingerprint");

    rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .context("building the TLS server config")
}

fn load_pem_pair(
    cert_path: &std::path::Path,
    key_path: &std::path::Path,
) -> Result<(Vec<CertificateDer<'static>>, PrivateKeyDer<'static>)> {
    let cert_pem = std::fs::read(cert_path)
        .with_context(|| format!("reading certificate {cert_path:?}"))?;
    let key_pem = std::fs::read(key_path)
        .with_context(|| format!("reading private key {key_path:?}"))?;

    let certs = CertificateDer::pem_slice_iter(cert_pem.as_slice())
        .collect::<Result<Vec<CertificateDer<'static>>, _>>()
        .context("parsing certificate PEM")?;
    if certs.is_empty() {
        bail!("no certificates found in {cert_path:?}");
    }

    let key = PrivateKeyDer::from_pem_slice(key_pem.as_slice())
        .context("parsing private key PEM")?;

    Ok((certs, key))
}

/// Generates an ephemeral self-signed certificate. Fine for a self-hosted
/// destination the user pins by fingerprint; pass --cert/--key for a real
/// certificate.
fn generate_self_signed() -> Result<(Vec<CertificateDer<'static>>, PrivateKeyDer<'static>)> {
    warn!("no --cert/--key given: generating a self-signed certificate for this run");

    let generated = rcgen::generate_simple_self_signed(vec!["silod".to_string()])
        .context("generating a self-signed certificate")?;

    let cert = generated.cert.der().clone();
    let key = PrivatePkcs8KeyDer::from(generated.key_pair.serialize_der());

    Ok((vec![cert], PrivateKeyDer::Pkcs8(key)))
}
