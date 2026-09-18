//! Lexe Connect PoC v2: RFC 9180 base mode, X25519/HKDF-SHA256/AES-128-GCM.

use anyhow::{Context, ensure};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use hpke::{Deserializable, Kem, OpModeS, Serializable};
use lexe_crypto::rng::{RngCore, SysRng};

type ConnectKem = hpke::kem::X25519HkdfSha256;

// Adapt the application's system RNG to HPKE's rand_core 0.9 interface.
struct ConnectRng(SysRng);
impl hpke::rand_core::RngCore for ConnectRng {
    fn next_u32(&mut self) -> u32 {
        self.0.next_u32()
    }
    fn next_u64(&mut self) -> u64 {
        self.0.next_u64()
    }
    fn fill_bytes(&mut self, dest: &mut [u8]) {
        self.0.fill_bytes(dest);
    }
}
impl hpke::rand_core::CryptoRng for ConnectRng {}

/// Returns base64url(enc || ciphertext), including the AES-GCM tag.
/// AAD is the exact original Connect URL in UTF-8, before URI normalization.
/// No credentials, keys, or URLs should be logged by callers.
pub fn encrypt_connect_response(
    recipient_key: String,
    request_uri: String,
    plaintext: String,
) -> anyhow::Result<String> {
    encrypt_with_rng(
        &recipient_key,
        &request_uri,
        &plaintext,
        &mut ConnectRng(SysRng::new()),
    )
}

fn encrypt_with_rng(
    recipient_key: &str,
    request_uri: &str,
    plaintext: &str,
    rng: &mut impl hpke::rand_core::CryptoRng,
) -> anyhow::Result<String> {
    ensure!(request_uri.len() <= 8192, "Connect request too large");
    ensure!(plaintext.len() <= 65536, "Connect response too large");
    let bytes = URL_SAFE_NO_PAD
        .decode(recipient_key)
        .context("Invalid Connect encryption key")?;
    let pk = <ConnectKem as Kem>::PublicKey::from_bytes(&bytes)
        .map_err(|_| anyhow::anyhow!("Invalid Connect encryption key"))?;
    let (enc, mut sender) = hpke::setup_sender::<
        hpke::aead::AesGcm128,
        hpke::kdf::HkdfSha256,
        ConnectKem,
        _,
    >(&OpModeS::Base, &pk, b"lexe-connect/v2", rng)
    .map_err(|_| anyhow::anyhow!("Invalid Connect encryption key"))?;
    let ciphertext = sender
        .seal(plaintext.as_bytes(), request_uri.as_bytes())
        .map_err(|_| anyhow::anyhow!("Connect encryption failed"))?;
    let mut envelope = enc.to_bytes().to_vec();
    envelope.extend_from_slice(&ciphertext);
    Ok(URL_SAFE_NO_PAD.encode(envelope))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn response_is_bound_to_request() {
        let (sk, pk) = ConnectKem::gen_keypair(&mut ConnectRng(SysRng::new()));
        let request = "https://zaprite.bolt12.rocks/lexe/connect?v=1";
        let envelope = encrypt_connect_response(
            URL_SAFE_NO_PAD.encode(pk.to_bytes()),
            request.into(),
            "test-credential".into(),
        )
        .unwrap();
        let bytes = URL_SAFE_NO_PAD.decode(envelope).unwrap();
        let enc =
            <ConnectKem as Kem>::EncappedKey::from_bytes(&bytes[..32]).unwrap();
        let receiver = || {
            hpke::setup_receiver::<
                hpke::aead::AesGcm128,
                hpke::kdf::HkdfSha256,
                ConnectKem,
            >(&hpke::OpModeR::Base, &sk, &enc, b"lexe-connect/v2")
            .unwrap()
        };
        assert_eq!(
            receiver().open(&bytes[32..], request.as_bytes()).unwrap(),
            b"test-credential"
        );
        assert!(receiver().open(&bytes[32..], b"different request").is_err());
    }

    // Disposable deterministic RNG, used only to publish reproducible vectors.
    struct VectorRng;
    impl hpke::rand_core::RngCore for VectorRng {
        fn next_u32(&mut self) -> u32 {
            0x42424242
        }
        fn next_u64(&mut self) -> u64 {
            0x4242424242424242
        }
        fn fill_bytes(&mut self, dest: &mut [u8]) {
            dest.fill(0x42);
        }
    }
    impl hpke::rand_core::CryptoRng for VectorRng {}

    #[test]
    fn shared_wire_vectors() {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../app/test/fixtures/lexe-connect-v2.json");
        let mut fixture: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        let sk_bytes = URL_SAFE_NO_PAD
            .decode(fixture["recipient_private_key"].as_str().unwrap())
            .unwrap();
        let sk =
            <ConnectKem as Kem>::PrivateKey::from_bytes(&sk_bytes).unwrap();
        let pk = URL_SAFE_NO_PAD.encode(ConnectKem::sk_to_pk(&sk).to_bytes());
        assert_eq!(pk, fixture["recipient_public_key"].as_str().unwrap());
        let request = fixture["request_uri"].as_str().unwrap().to_owned();
        for case in fixture["responses"].as_array_mut().unwrap() {
            let plaintext = case["plaintext"].as_str().unwrap();
            let actual =
                encrypt_with_rng(&pk, &request, plaintext, &mut VectorRng)
                    .unwrap();
            let bytes = URL_SAFE_NO_PAD.decode(&actual).unwrap();
            let enc =
                <ConnectKem as Kem>::EncappedKey::from_bytes(&bytes[..32])
                    .unwrap();
            let receiver = || {
                hpke::setup_receiver::<
                    hpke::aead::AesGcm128,
                    hpke::kdf::HkdfSha256,
                    ConnectKem,
                >(
                    &hpke::OpModeR::Base, &sk, &enc, b"lexe-connect/v2"
                )
                .unwrap()
            };
            assert_eq!(
                receiver().open(&bytes[32..], request.as_bytes()).unwrap(),
                plaintext.as_bytes()
            );
            assert!(receiver().open(&bytes[32..], b"wrong request").is_err());
            let mut corrupt = bytes[32..].to_vec();
            corrupt[0] ^= 1;
            assert!(receiver().open(&corrupt, request.as_bytes()).is_err());
            if std::env::var_os("LEXE_CONNECT_UPDATE_VECTORS").is_some() {
                case["credential_ciphertext"] = actual.clone().into();
                case["callback_uri"] = format!(
                    "https://zaprite.bolt12.rocks/lexe/callback?existing=one&existing=two#v=2&request_id=abcdefghijklmnopqrstuv&credential_ciphertext={actual}"
                ).into();
            } else {
                assert_eq!(
                    case["credential_ciphertext"].as_str().unwrap(),
                    actual
                );
            }
        }
        if std::env::var_os("LEXE_CONNECT_UPDATE_VECTORS").is_some() {
            std::fs::write(
                path,
                serde_json::to_string_pretty(&fixture).unwrap() + "\n",
            )
            .unwrap();
        }
    }

    #[test]
    fn rejects_low_order_key() {
        assert!(
            encrypt_connect_response(
                URL_SAFE_NO_PAD.encode([0; 32]),
                "request".into(),
                "secret".into()
            )
            .is_err()
        );
    }
}
