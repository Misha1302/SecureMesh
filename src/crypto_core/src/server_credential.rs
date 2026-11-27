//! Shared by the native client and the browser WASM build.
use anyhow::{ensure, Result};
use base64::{engine::general_purpose::STANDARD as B64, Engine};

pub(crate) fn validate_principal(endpoint: &str, username: &str) -> Result<()> {
    ensure!(
        endpoint.starts_with("https://")
            && endpoint.len() > 8
            && endpoint.len() <= 2048
            && !endpoint[8..].contains(['/', '?', '#', '@'])
            && !endpoint.chars().any(char::is_whitespace),
        "invalid origin"
    );
    ensure!(
        (3..=32).contains(&username.len())
            && username
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_'),
        "invalid username"
    );
    Ok(())
}

pub(crate) fn derive_server_credential(
    origin: &str,
    username: &str,
    password: &str,
) -> Result<String> {
    use argon2::{Algorithm, Argon2, Params, Version};
    use sha2::{Digest, Sha256};
    use unicode_segmentation::UnicodeSegmentation;
    validate_principal(origin, username)?;
    ensure!(
        password.len() <= 4096
            && !password.contains('\0')
            && (16..=256).contains(&password.graphemes(true).count()),
        "invalid passphrase length"
    );
    let salt = Sha256::digest(
        [
            b"SecureMesh/server-credential/v2\0",
            origin.as_bytes(),
            b"\0",
            username.as_bytes(),
        ]
        .concat(),
    );
    let params = Params::new(65536, 3, 4, Some(32))
        .map_err(|_| anyhow::anyhow!("invalid KDF parameters"))?;
    let mut output = [0u8; 32];
    Argon2::new(Algorithm::Argon2id, Version::V0x13, params)
        .hash_password_into(password.as_bytes(), &salt, &mut output)
        .map_err(|_| anyhow::anyhow!("credential derivation failed"))?;
    Ok(B64.encode(output))
}
