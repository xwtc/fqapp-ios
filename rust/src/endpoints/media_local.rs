//! Decrypted local media for platforms without a native CENC decryptor.
//!
//! Android decrypts while streaming: ExoPlayer reads through
//! `libshortplay_crypto.so`, which patches the MP4 in place and keeps every
//! byte offset stable. iOS has no equivalent, so `AVPlayer` can only be handed
//! plaintext. Rather than port the 47 KB C CENC walk to Swift (and keep two
//! implementations in step against the same golden vectors), the core
//! downloads once, decrypts in place, and serves the result from `/src/` with
//! Range support — the same path the non-stream video response already uses.
//!
//! The endpoint is deliberately narrow: it only accepts http(s) URLs, only
//! writes inside `src_dir`, and never returns the key.

use futures::future::BoxFuture;
use serde_json::json;
use std::path::{Path, PathBuf};

use crate::endpoints::{Ctx, Params, Server};
use crate::error::{ApiError, ApiResult};

/// Cap on a single decrypted media file. A short-drama episode is far below
/// this; the bound stops a lying Content-Length from filling the disk.
const MAX_LOCAL_MEDIA_BYTES: u64 = 2 * 1024 * 1024 * 1024;

/// Serialises download+decrypt per file. Two concurrent requests for the same
/// id would otherwise both write `<id>.part` and corrupt each other.
static LOCAL_MEDIA_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

pub fn handle_media_local<'a>(
    ctx: &'a Ctx,
    params: &'a Params,
) -> BoxFuture<'a, ApiResult<serde_json::Value>> {
    Box::pin(async move {
        let url = params.get_str("url");
        if url.trim().is_empty() {
            return Err(ApiError::BadRequest("missing url parameter".to_string()));
        }
        let parsed = url::Url::parse(url.trim())
            .map_err(|e| ApiError::BadRequest(format!("invalid url: {e}")))?;
        if parsed.scheme() != "http" && parsed.scheme() != "https" {
            return Err(ApiError::BadRequest(
                "only http(s) media urls are supported".to_string(),
            ));
        }
        if parsed.host_str().unwrap_or("").is_empty() {
            return Err(ApiError::BadRequest("url has no host".to_string()));
        }

        // The key arrives as hex from the same `encrypt_info` the Dart side
        // already parses. An empty key means the stream is unencrypted.
        let key_hex = params.get_str("key_hex");
        let key = if key_hex.trim().is_empty() {
            Vec::new()
        } else {
            let bytes = hex::decode(key_hex.trim())
                .map_err(|e| ApiError::BadRequest(format!("invalid key_hex: {e}")))?;
            if bytes.len() != 16 {
                return Err(ApiError::BadRequest(format!(
                    "key_hex must be 16 bytes, got {}",
                    bytes.len()
                )));
            }
            bytes
        };

        let id = local_id(params, &parsed);
        let served = ensure_local_media(ctx, &id, url.trim(), &key)
            .await
            .map_err(ApiError::Internal)?;

        Ok(json!({
            "success": true,
            "data": {
                "url": served,
                // Encrypted input is always plaintext on disk after this call,
                // so the client must not try to decrypt it again.
                "decrypted": !key.is_empty(),
            }
        }))
    })
}

/// Stable, filesystem-safe cache name. The caller may pass an explicit `id`
/// (the episode id, which keeps the cache warm across quality changes);
/// otherwise the URL's last path segment is used.
fn local_id(params: &Params, url: &url::Url) -> String {
    let raw = {
        let given = params.get_str("id");
        if given.trim().is_empty() {
            url.path_segments()
                .and_then(|s| s.last())
                .unwrap_or("media")
                .to_string()
        } else {
            given
        }
    };
    let mut out = String::with_capacity(raw.len());
    for ch in raw.chars() {
        if ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' {
            out.push(ch);
        } else {
            out.push('_');
        }
    }
    if out.is_empty() {
        out.push_str("media");
    }
    // Keep room for the extension and `.part` suffix.
    out.truncate(96);
    out
}

async fn ensure_local_media(
    ctx: &Ctx,
    id: &str,
    url: &str,
    key: &[u8],
) -> Result<String, String> {
    let _guard = LOCAL_MEDIA_LOCK.lock().await;

    let src_dir = if ctx.src_dir.is_empty() {
        "src".to_string()
    } else {
        ctx.src_dir.clone()
    };
    std::fs::create_dir_all(&src_dir).map_err(|e| e.to_string())?;

    let ext = media_ext(url);
    let filename = format!("{id}{ext}");
    let fp = Path::new(&src_dir).join(&filename);

    // A file that already exists was decrypted by whoever wrote it, because
    // every write below finishes decryption before the rename.
    if let Ok(meta) = std::fs::metadata(&fp) {
        if meta.len() > 0 {
            return Ok(format!("/src/{filename}"));
        }
    }

    let part = PathBuf::from(format!("{}.part", fp.display()));
    let _ = std::fs::remove_file(&part);

    let download_url = ctx.up.effective_url(url);
    super::video::stream_media_to_file(&download_url, &part, MAX_LOCAL_MEDIA_BYTES)
        .await
        .map_err(|e| {
            let _ = std::fs::remove_file(&part);
            e
        })?;

    if !key.is_empty() {
        // Whole-file decrypt is fine here: the CENC walk needs the moov box and
        // random access to the sample tables, and the Rust implementation is
        // already bounded by MAX_LOCAL_MEDIA_BYTES.
        let mut owned = std::fs::read(&part).map_err(|e| {
            let _ = std::fs::remove_file(&part);
            e.to_string()
        })?;
        super::video::decrypt_cenc_in_place(&mut owned, key).map_err(|e| {
            let _ = std::fs::remove_file(&part);
            e
        })?;
        std::fs::write(&part, &owned).map_err(|e| {
            let _ = std::fs::remove_file(&part);
            e.to_string()
        })?;
    }

    std::fs::rename(&part, &fp).map_err(|e| {
        let _ = std::fs::remove_file(&part);
        e.to_string()
    })?;
    super::video::prune_src_cache(&src_dir, &fp);

    Ok(format!("/src/{filename}"))
}

fn media_ext(url: &str) -> String {
    let path = url::Url::parse(url)
        .map(|u| u.path().to_string())
        .unwrap_or_default();
    let candidate = path.rsplit('.').next().unwrap_or("").to_lowercase();
    match candidate.as_str() {
        "mp4" => ".mp4".to_string(),
        "m4a" => ".m4a".to_string(),
        "mp3" => ".mp3".to_string(),
        "m4s" => ".m4s".to_string(),
        "ts" => ".ts".to_string(),
        // Audio sources are usually served without an extension; AVPlayer
        // sniffs the container, so a generic name is fine.
        _ => ".mp4".to_string(),
    }
}

/// Registers the decrypted-media endpoint.
pub fn register(s: &mut Server) {
    s.add_route("media_local", handle_media_local);
}
