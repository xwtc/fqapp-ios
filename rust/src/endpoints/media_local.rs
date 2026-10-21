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
use sha2::{Digest, Sha256};
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

/// Cache name for one media URL.
///
/// The name MUST be derived from the full URL, not just its last path segment.
/// CDN media URLs frequently end in a directory, a generic name, or nothing at
/// all, so a stem-only key made every episode resolve to `media.mp4`; the first
/// download then answered every later request and the app played that one file
/// for all content (including audio, which shares this cache).
///
/// The caller's `id` is kept only as a readable prefix. The hash is what
/// guarantees uniqueness, so a bad or colliding id can never alias two files.
fn local_id(params: &Params, url: &url::Url) -> String {
    let given = params.get_str("id");
    let raw = if given.trim().is_empty() {
        url.path_segments()
            .and_then(|s| s.last())
            .unwrap_or("media")
            .to_string()
    } else {
        given
    };

    // Strip the extension: `media_ext` re-adds a normalised one, and leaving it
    // in would produce `clip.mp4-1a2b3c4d.mp4`.
    let stem = raw.split('.').next().unwrap_or("media");
    let mut prefix = String::with_capacity(stem.len());
    for ch in stem.chars() {
        if ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' {
            prefix.push(ch);
        } else {
            prefix.push('_');
        }
    }
    let prefix = prefix.trim_matches('_');
    let prefix = if prefix.is_empty() { "media" } else { prefix };
    // Every byte pushed above is ASCII (anything else became '_'), so a byte
    // slice here cannot split a UTF-8 scalar. The explicit filter keeps that
    // true if the loop ever changes.
    debug_assert!(prefix.is_ascii());
    let prefix = &prefix[..prefix.len().min(64)];

    let mut hasher = Sha256::new();
    hasher.update(url.as_str().as_bytes());
    let digest = hasher.finalize();
    let hash: String = digest.iter().take(4).map(|b| format!("{b:02x}")).collect();

    format!("{prefix}-{hash}")
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

#[cfg(test)]
mod tests {
    use super::*;

    fn params(pairs: &[(&str, &str)]) -> Params {
        let mut p = Params::new();
        for (k, v) in pairs {
            p.set(k, v);
        }
        p
    }

    fn url(raw: &str) -> url::Url {
        url::Url::parse(raw).expect("test url")
    }

    /// The bug this guards: every CDN URL used to collapse to the same cache
    /// name, so the first download answered every later request and the app
    /// replayed that one file for all content.
    #[test]
    fn different_urls_never_share_a_cache_name() {
        let a = url("https://cdn.test/video/abc/ep1.mp4");
        let b = url("https://cdn.test/video/abc/ep2.mp4");
        let c = url("https://cdn.test/audio/xyz/tone0.m4a");
        let names = [
            local_id(&params(&[("id", "ep1")]), &a),
            local_id(&params(&[("id", "ep2")]), &b),
            local_id(&params(&[("id", "tone0")]), &c),
        ];
        for (i, x) in names.iter().enumerate() {
            for y in names.iter().skip(i + 1) {
                assert_ne!(x, y, "cache names collided: {x} == {y}");
            }
        }
    }

    /// A caller-supplied id that collides (or is missing) must not alias two
    /// different URLs: the hash is the discriminator.
    #[test]
    fn same_id_with_different_urls_still_differs() {
        let a = url("https://cdn.test/a.mp4");
        let b = url("https://cdn.test/b.mp4");
        let p = params(&[("id", "media")]);
        assert_ne!(local_id(&p, &a), local_id(&p, &b));
    }

    /// The same URL must map to the same name, or the cache never hits.
    #[test]
    fn same_url_is_stable() {
        let a = url("https://cdn.test/video/abc/ep1.mp4");
        let p = params(&[("id", "ep1")]);
        assert_eq!(local_id(&p, &a), local_id(&p, &a));
    }

    /// URLs that end in a directory or carry a query are the cases the old
    /// stem-only key got wrong.
    #[test]
    fn urls_without_a_filename_still_differ() {
        let a = url("https://cdn.test/video/abc/");
        let b = url("https://cdn.test/video/def/");
        assert_ne!(local_id(&params(&[]), &a), local_id(&params(&[]), &b));

        let c = url("https://cdn.test/play?episode=1");
        let d = url("https://cdn.test/play?episode=2");
        assert_ne!(local_id(&params(&[]), &c), local_id(&params(&[]), &d));
    }

    /// The name must stay filesystem-safe: only ASCII alnum, '-' and '_'.
    #[test]
    fn cache_name_is_filesystem_safe() {
        let u = url("https://cdn.test/video/%E4%B8%AD%E6%96%87/clip.mp4?x=1");
        let name = local_id(&params(&[("id", "../../etc/passwd")]), &u);
        assert!(
            name.chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_'),
            "unsafe cache name: {name}"
        );
        assert!(!name.contains(".."), "path traversal in {name}");
        assert!(!name.contains('/'), "path separator in {name}");
    }
}
