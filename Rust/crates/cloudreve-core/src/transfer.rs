use crate::{SourceFingerprint, UploadPart, UploadSessionState};
use aes::Aes256;
use cloudreve_protocol::{CapabilitySnapshot, CapabilityState};
use ctr::cipher::{KeyIvInit, StreamCipher, StreamCipherSeek};
use sha2::{Digest, Sha256};

type Aes256Ctr = ctr::Ctr128BE<Aes256>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChunkDescriptor {
    pub index: u32,
    pub offset: u64,
    pub length: u64,
}

pub fn plan_chunks(file_size: u64, chunk_size: u64) -> Vec<ChunkDescriptor> {
    let chunk_size = chunk_size.max(1);
    if file_size == 0 {
        return vec![ChunkDescriptor { index: 0, offset: 0, length: 0 }];
    }
    (0..file_size.div_ceil(chunk_size))
        .map(|index| {
            let offset = index * chunk_size;
            ChunkDescriptor { index: index as u32, offset, length: (file_size - offset).min(chunk_size) }
        })
        .collect()
}

pub fn plaintext_hash(bytes: &[u8]) -> Vec<u8> {
    Sha256::digest(bytes).to_vec()
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UploadRecoveryDecision {
    ResumePending { parts: Vec<UploadPart> },
    VerifyCompletion,
    AbandonSourceChanged,
    AbandonExpired,
}

pub fn recover_upload(session: &UploadSessionState, fingerprint: &SourceFingerprint, now: i64) -> UploadRecoveryDecision {
    if session.fingerprint != *fingerprint { return UploadRecoveryDecision::AbandonSourceChanged; }
    if session.expires_at.map(|expires| expires <= now).unwrap_or(false) { return UploadRecoveryDecision::AbandonExpired; }
    if session.parts.iter().all(|part| part.state == "completed") { return UploadRecoveryDecision::VerifyCompletion; }
    UploadRecoveryDecision::ResumePending { parts: session.pending_parts().cloned().collect() }
}

pub fn encrypt_aes_ctr_at_offset(key: &[u8; 32], iv: &[u8; 16], offset: u64, plaintext: &mut [u8]) {
    let mut cipher = Aes256Ctr::new(key.into(), iv.into());
    cipher.seek(offset);
    cipher.apply_keystream(plaintext);
}

pub fn encrypted_chunks(key: &[u8; 32], iv: &[u8; 16], plaintext: &[u8], chunks: &[ChunkDescriptor]) -> Vec<Vec<u8>> {
    chunks.iter().map(|chunk| {
        let start = chunk.offset as usize;
        let end = start.saturating_add(chunk.length as usize).min(plaintext.len());
        let mut part = plaintext.get(start..end).unwrap_or_default().to_vec();
        encrypt_aes_ctr_at_offset(key, iv, chunk.offset, &mut part);
        part
    }).collect()
}

pub fn provider_is_write_capable(snapshot: &CapabilitySnapshot, provider: &str) -> bool {
    snapshot.allows_write()
        && snapshot.provider(provider).map(|capability| {
            capability.write == CapabilityState::Verified
                && capability.resumable == CapabilityState::Verified
                && capability.zero_byte == CapabilityState::Verified
        }).unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::UploadSessionState;
    use cloudreve_protocol::{CapabilitySnapshot, CapabilityState, ProviderCapability};
    use uuid::Uuid;

    #[test]
    fn chunk_planner_handles_empty_and_tail_chunks() {
        assert_eq!(plan_chunks(0, 4), vec![ChunkDescriptor { index: 0, offset: 0, length: 0 }]);
        assert_eq!(plan_chunks(10, 4), vec![
            ChunkDescriptor { index: 0, offset: 0, length: 4 },
            ChunkDescriptor { index: 1, offset: 4, length: 4 },
            ChunkDescriptor { index: 2, offset: 8, length: 2 },
        ]);
    }

    #[test]
    fn absolute_ctr_offset_matches_whole_file_encryption() {
        let key = [7u8; 32];
        let iv = [3u8; 16];
        let plaintext = b"Cloudreve content crosses chunk boundaries.";
        let whole = encrypted_chunks(&key, &iv, plaintext, &[ChunkDescriptor { index: 0, offset: 0, length: plaintext.len() as u64 }]).remove(0);
        let chunks = encrypted_chunks(&key, &iv, plaintext, &plan_chunks(plaintext.len() as u64, 7));
        let joined = chunks.into_iter().flatten().collect::<Vec<_>>();
        assert_eq!(joined, whole);
    }

    #[test]
    fn recovery_rejects_changed_source_and_resumes_only_pending_parts() {
        let fingerprint = SourceFingerprint::from_bytes(b"same", None, 3);
        let session = UploadSessionState { operation_id: Uuid::new_v4(), remote_session_ref: "session".into(), secret_ref: "secret".into(), fingerprint: fingerprint.clone(), provider: "s3".into(), chunk_size: 4, expires_at: Some(2_000), parts: vec![UploadPart { index: 0, offset: 0, length: 4, plaintext_hash: vec![1], etag: Some("etag".into()), state: "completed".into() }, UploadPart { index: 1, offset: 4, length: 2, plaintext_hash: vec![2], etag: None, state: "pending".into() }], state: "active".into() };
        assert_eq!(recover_upload(&session, &fingerprint, 1_000), UploadRecoveryDecision::ResumePending { parts: vec![session.parts[1].clone()] });
        assert_eq!(recover_upload(&session, &SourceFingerprint::from_bytes(b"changed", None, 3), 1_000), UploadRecoveryDecision::AbandonSourceChanged);
        assert_eq!(recover_upload(&session, &fingerprint, 2_000), UploadRecoveryDecision::AbandonExpired);
    }

    #[test]
    fn provider_matrix_fails_closed_for_unknown_or_incomplete_capabilities() {
        let mut snapshot = CapabilitySnapshot::read_only_default();
        snapshot.stable_item_identity = CapabilityState::Verified;
        snapshot.stable_root_identity = CapabilityState::Verified;
        snapshot.conditional_content_write = CapabilityState::Verified;
        snapshot.idempotent_create = CapabilityState::Verified;
        snapshot.providers.push(ProviderCapability { provider: "s3".into(), read: CapabilityState::Verified, write: CapabilityState::Verified, resumable: CapabilityState::Verified, zero_byte: CapabilityState::Unverified, crypto: CapabilityState::Verified });
        assert!(!provider_is_write_capable(&snapshot, "s3"));
        assert!(!provider_is_write_capable(&snapshot, "missing"));
    }
}

