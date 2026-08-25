//! Durable use cases shared by the macOS app and File Provider extension.

mod api;
mod reconcile;
mod transfer;

pub use api::{CloudreveHttpClient, SseSubscription};
pub use reconcile::{
    root_identity_after_check, tombstone_candidates, ReconcilePhase, ReconcileRun,
};
pub use transfer::{
    encrypt_aes_ctr_at_offset, encrypted_chunks, plaintext_hash, plan_chunks,
    provider_is_write_capable, recover_upload, UploadRecoveryDecision,
};

use cloudreve_protocol::{CapabilitySnapshot, RemoteItem, RemoteItemKind};
use cloudreve_store::{ItemRecord, OperationRecord, StateStore, StoreError};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use thiserror::Error;
use uuid::Uuid;

pub const CORE_API_VERSION: u32 = 1;

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum CoreError {
    #[error("authentication required")]
    Authentication,
    #[error("server is unreachable")]
    Network,
    #[error("permission denied")]
    PermissionDenied,
    #[error("item was not found")]
    NotFound,
    #[error("quota exceeded")]
    QuotaExceeded,
    #[error("remote version conflict")]
    VersionConflict,
    #[error("filename collision")]
    NameCollision,
    #[error("invalid name")]
    InvalidName,
    #[error("content integrity check failed")]
    IntegrityFailure,
    #[error("operation was cancelled")]
    Cancelled,
    #[error("unsupported server capability")]
    UnsupportedServer,
    #[error("database error: {0}")]
    Database(String),
    #[error("unsupported metadata")]
    UnsupportedMetadata,
    #[error("remote root is unavailable")]
    RootUnavailable,
    #[error("operation outcome is unknown")]
    UnknownOutcome,
    #[error("operation is waiting for a callback replay")]
    AwaitingSourceReplay,
    #[error("conflict requires user resolution")]
    Conflict,
}

impl From<StoreError> for CoreError {
    fn from(error: StoreError) -> Self {
        Self::Database(error.to_string())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OperationKind {
    Create,
    Modify,
    Rename,
    Move,
    Trash,
    Restore,
    Delete,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OperationState {
    Queued,
    Preflight,
    RemoteSubmitted,
    Verifying,
    AwaitingSourceReplay,
    RetryWait,
    Conflict,
    Committed,
    PermanentlyFailed,
    Cancelled,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OperationIntent {
    pub operation_id: Uuid,
    pub replay_key: String,
    pub kind: OperationKind,
    pub item_id: Option<Uuid>,
    pub expected_version: Option<Vec<u8>>,
    pub changed_fields: Vec<String>,
    pub source_generation: u64,
}

impl OperationIntent {
    pub fn as_store_record(&self) -> OperationRecord {
        OperationRecord {
            operation_id: self.operation_id,
            replay_key: self.replay_key.clone(),
            kind: format!("{:?}", self.kind).to_lowercase(),
            item_id: self.item_id,
            state: "queued".into(),
            source_generation: self.source_generation,
            cancel_requested: false,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SourceFingerprint {
    pub size: u64,
    pub base_version: Option<Vec<u8>>,
    pub edge_sha256: Vec<u8>,
    pub source_generation: u64,
}

impl SourceFingerprint {
    pub fn from_bytes(data: &[u8], base_version: Option<Vec<u8>>, source_generation: u64) -> Self {
        let edge = if data.len() <= 128 * 1024 {
            data.to_vec()
        } else {
            let edge_size = 64 * 1024;
            [
                data[..edge_size].to_vec(),
                data[data.len() - edge_size..].to_vec(),
            ]
            .concat()
        };
        let mut hasher = Sha256::new();
        hasher.update((data.len() as u64).to_be_bytes());
        hasher.update(&edge);
        Self {
            size: data.len() as u64,
            base_version,
            edge_sha256: hasher.finalize().to_vec(),
            source_generation,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UploadPart {
    pub index: u32,
    pub offset: u64,
    pub length: u64,
    pub plaintext_hash: Vec<u8>,
    pub etag: Option<String>,
    pub state: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UploadSessionState {
    pub operation_id: Uuid,
    pub remote_session_ref: String,
    pub secret_ref: String,
    pub fingerprint: SourceFingerprint,
    pub provider: String,
    pub chunk_size: u64,
    pub expires_at: Option<i64>,
    pub parts: Vec<UploadPart>,
    pub state: String,
}

impl UploadSessionState {
    pub fn pending_parts(&self) -> impl Iterator<Item = &UploadPart> {
        self.parts.iter().filter(|part| part.state != "completed")
    }

    pub fn can_resume_with(&self, fingerprint: &SourceFingerprint, now: i64) -> bool {
        self.fingerprint == *fingerprint
            && self.expires_at.map(|expires| expires > now).unwrap_or(true)
            && self.state != "abandoned"
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConflictRecord {
    pub conflict_id: Uuid,
    pub item_id: Uuid,
    pub kind: String,
    pub base_summary: String,
    pub remote_summary: String,
    pub local_summary: String,
    pub pending_item_id: Option<String>,
    pub source_generation: u64,
    pub state: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResolutionAction {
    KeepRemote,
    OverwriteRemote,
    KeepBoth,
}

pub trait RemoteGateway {
    fn get_item(&self, item_id: &str) -> Result<RemoteItem, CoreError>;
    fn create_folder(
        &mut self,
        parent_id: &str,
        name: &str,
        replay_key: &str,
    ) -> Result<RemoteItem, CoreError>;
    fn create_file(
        &mut self,
        parent_id: &str,
        name: &str,
        content: &[u8],
        replay_key: &str,
    ) -> Result<RemoteItem, CoreError>;
    fn modify_file(
        &mut self,
        item_id: &str,
        expected_version: &[u8],
        name: Option<&str>,
        content: Option<&[u8]>,
    ) -> Result<RemoteItem, CoreError>;
    fn move_item(
        &mut self,
        item_id: &str,
        expected_version: &[u8],
        parent_id: &str,
        name: Option<&str>,
    ) -> Result<RemoteItem, CoreError>;
    fn trash_item(
        &mut self,
        item_id: &str,
        expected_version: &[u8],
    ) -> Result<RemoteItem, CoreError>;
    fn restore_item(
        &mut self,
        item_id: &str,
        expected_version: &[u8],
        parent_id: &str,
    ) -> Result<RemoteItem, CoreError>;
    fn delete_item(
        &mut self,
        item_id: &str,
        expected_version: &[u8],
        recursive: bool,
    ) -> Result<(), CoreError>;
}

pub struct MutationCoordinator<'a, R: RemoteGateway> {
    pub store: &'a mut StateStore,
    pub remote: &'a mut R,
}

impl<'a, R: RemoteGateway> MutationCoordinator<'a, R> {
    pub fn ensure_operation(
        &mut self,
        intent: &OperationIntent,
    ) -> Result<OperationRecord, CoreError> {
        Ok(self.store.upsert_operation(&intent.as_store_record())?)
    }

    pub fn create_folder(
        &mut self,
        intent: &OperationIntent,
        parent_id: &str,
        name: &str,
    ) -> Result<RemoteItem, CoreError> {
        let existing = self.ensure_operation(intent)?;
        if existing.state == "committed" {
            if let Some(outcome) = self
                .store
                .operation_outcome(&intent.replay_key)?
                .and_then(|(_, _, value)| value)
            {
                return serde_json::from_str(&outcome).map_err(|_| CoreError::UnknownOutcome);
            }
            return Err(CoreError::UnknownOutcome);
        }
        let item = self
            .remote
            .create_folder(parent_id, name, &intent.replay_key)?;
        let local_id = stable_local_id(&intent.replay_key);
        self.store
            .insert_item(&item_record(&item, local_id, parent_id))?;
        let outcome = serde_json::to_string(&item).map_err(|_| CoreError::UnknownOutcome)?;
        self.store.commit_operation(
            intent.operation_id,
            "committed",
            Some(local_id),
            Some(&outcome),
        )?;
        Ok(item)
    }

    pub fn create_file(
        &mut self,
        intent: &OperationIntent,
        parent_id: &str,
        name: &str,
        content: &[u8],
    ) -> Result<RemoteItem, CoreError> {
        let existing = self.ensure_operation(intent)?;
        if existing.state == "committed" {
            if let Some(outcome) = self
                .store
                .operation_outcome(&intent.replay_key)?
                .and_then(|(_, _, value)| value)
            {
                return serde_json::from_str(&outcome).map_err(|_| CoreError::UnknownOutcome);
            }
            return Err(CoreError::UnknownOutcome);
        }
        let item = self
            .remote
            .create_file(parent_id, name, content, &intent.replay_key)?;
        let local_id = stable_local_id(&intent.replay_key);
        self.store
            .insert_item(&item_record(&item, local_id, parent_id))?;
        let outcome = serde_json::to_string(&item).map_err(|_| CoreError::UnknownOutcome)?;
        self.store.commit_operation(
            intent.operation_id,
            "committed",
            Some(local_id),
            Some(&outcome),
        )?;
        Ok(item)
    }

    pub fn modify_file(
        &mut self,
        intent: &OperationIntent,
        remote_id: &str,
        name: Option<&str>,
        content: Option<&[u8]>,
    ) -> Result<RemoteItem, CoreError> {
        let existing = self.ensure_operation(intent)?;
        if existing.state == "committed" {
            if let Some(outcome) = self
                .store
                .operation_outcome(&intent.replay_key)?
                .and_then(|(_, _, value)| value)
            {
                return serde_json::from_str(&outcome).map_err(|_| CoreError::UnknownOutcome);
            }
            return Err(CoreError::UnknownOutcome);
        }
        let expected = intent
            .expected_version
            .as_deref()
            .ok_or(CoreError::VersionConflict)?;
        let item = self
            .remote
            .modify_file(remote_id, expected, name, content)?;
        let outcome = serde_json::to_string(&item).map_err(|_| CoreError::UnknownOutcome)?;
        self.store.commit_operation(
            intent.operation_id,
            "committed",
            intent.item_id,
            Some(&outcome),
        )?;
        Ok(item)
    }

    pub fn delete(
        &mut self,
        intent: &OperationIntent,
        remote_id: &str,
        recursive: bool,
    ) -> Result<(), CoreError> {
        let existing = self.ensure_operation(intent)?;
        if existing.state == "committed" {
            return Ok(());
        }
        let expected = intent
            .expected_version
            .as_deref()
            .ok_or(CoreError::VersionConflict)?;
        self.remote.delete_item(remote_id, expected, recursive)?;
        self.store
            .commit_operation(intent.operation_id, "committed", intent.item_id, None)?;
        Ok(())
    }
}

fn item_version(item: &RemoteItem) -> Vec<u8> {
    item.content_etag
        .clone()
        .or(item.metadata_revision.clone())
        .unwrap_or_else(|| item.id.clone())
        .into_bytes()
}

fn stable_local_id(replay_key: &str) -> Uuid {
    let digest = Sha256::digest(replay_key.as_bytes());
    let mut bytes = [0u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    Uuid::from_bytes(bytes)
}

fn parent_uuid(parent_id: &str) -> Option<Uuid> {
    parent_id
        .strip_prefix("cri-")
        .and_then(|value| Uuid::parse_str(value).ok())
}

fn item_record(item: &RemoteItem, item_id: Uuid, parent_id: &str) -> ItemRecord {
    ItemRecord {
        item_id,
        remote_id: Some(item.id.clone()),
        parent_id: parent_uuid(parent_id),
        name: item.name.clone(),
        kind: format!("{:?}", item.kind).to_lowercase(),
        uri: item.uri.clone(),
        content_version: item_version(item),
        metadata_version: item
            .metadata_revision
            .clone()
            .unwrap_or_default()
            .into_bytes(),
        size: item.size,
        trashed: item.trashed,
        tombstone: false,
    }
}

pub struct Reconciliation;

impl Reconciliation {
    /// A missing item can become a tombstone only after both normal and trash
    /// scans completed and no active operation owns the item.
    pub fn tombstone_candidates(
        expected_remote_ids: &HashSet<String>,
        seen_normal: &HashSet<String>,
        seen_trash: &HashSet<String>,
        pending_remote_ids: &HashSet<String>,
        normal_scan_complete: bool,
        trash_scan_complete: bool,
    ) -> Vec<String> {
        if !normal_scan_complete || !trash_scan_complete {
            return Vec::new();
        }
        expected_remote_ids
            .iter()
            .filter(|id| {
                !seen_normal.contains(*id)
                    && !seen_trash.contains(*id)
                    && !pending_remote_ids.contains(*id)
            })
            .cloned()
            .collect()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HealthState {
    Healthy,
    Syncing,
    Reconciling,
    Offline,
    EventDegraded,
    AppNotRunning,
    Conflict,
    PermanentError,
    RootUnavailable,
    ScopeConflict,
    AuthExpired,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct HealthInputs {
    pub authenticated: bool,
    pub root_available: bool,
    pub scope_valid: bool,
    pub has_conflict: bool,
    pub has_permanent_error: bool,
    pub offline: bool,
    pub reconciling: bool,
    pub syncing: bool,
    pub event_degraded: bool,
    pub app_running: bool,
    pub valid_anchor: bool,
    pub recently_reconciled: bool,
}

pub fn reduce_health(input: &HealthInputs) -> HealthState {
    if !input.authenticated {
        return HealthState::AuthExpired;
    }
    if !input.root_available {
        return HealthState::RootUnavailable;
    }
    if !input.scope_valid {
        return HealthState::ScopeConflict;
    }
    if input.has_conflict {
        return HealthState::Conflict;
    }
    if input.has_permanent_error {
        return HealthState::PermanentError;
    }
    if input.offline {
        return HealthState::Offline;
    }
    if input.reconciling {
        return HealthState::Reconciling;
    }
    if input.syncing {
        return HealthState::Syncing;
    }
    if input.event_degraded {
        return HealthState::EventDegraded;
    }
    if !input.app_running {
        return HealthState::AppNotRunning;
    }
    if input.valid_anchor && input.recently_reconciled {
        return HealthState::Healthy;
    }
    HealthState::Reconciling
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EchoEvidence {
    pub remote_id: String,
    pub operation_id: Uuid,
    pub expected_parent: Option<String>,
    pub expected_name: Option<String>,
    pub expected_version: Option<Vec<u8>>,
}

pub fn is_local_echo(evidence: &EchoEvidence, item: &RemoteItem) -> bool {
    evidence.remote_id == item.id
        && evidence
            .expected_parent
            .as_ref()
            .map(|parent| item.parent_id.as_deref() == Some(parent))
            .unwrap_or(true)
        && evidence
            .expected_name
            .as_ref()
            .map(|name| name == &item.name)
            .unwrap_or(true)
        && evidence
            .expected_version
            .as_deref()
            .map(|version| item_version(item) == version)
            .unwrap_or(true)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RootCheck {
    pub expected_id: String,
    pub expected_uri: String,
    pub observed: Option<RemoteItem>,
}

pub fn validate_root(check: &RootCheck) -> Result<String, CoreError> {
    let observed = check.observed.as_ref().ok_or(CoreError::RootUnavailable)?;
    if observed.id != check.expected_id
        || observed.kind != RemoteItemKind::Folder
        || !observed.can_read
    {
        return Err(CoreError::RootUnavailable);
    }
    Ok(observed.uri.clone())
}

pub fn provider_can_write(capability: &CapabilitySnapshot, provider: &str) -> bool {
    capability.allows_write()
        && capability
            .provider(provider)
            .map(|value| {
                value.write == cloudreve_protocol::CapabilityState::Verified
                    && value.resumable == cloudreve_protocol::CapabilityState::Verified
                    && value.zero_byte == cloudreve_protocol::CapabilityState::Verified
            })
            .unwrap_or(false)
}

#[derive(Debug, Clone, Default)]
pub struct InMemoryRemote {
    pub items: HashMap<String, RemoteItem>,
    pub calls: Vec<String>,
}

impl RemoteGateway for InMemoryRemote {
    fn get_item(&self, item_id: &str) -> Result<RemoteItem, CoreError> {
        self.items.get(item_id).cloned().ok_or(CoreError::NotFound)
    }
    fn create_folder(
        &mut self,
        parent_id: &str,
        name: &str,
        replay_key: &str,
    ) -> Result<RemoteItem, CoreError> {
        if let Some(item) = self
            .items
            .values()
            .find(|item| item.parent_id.as_deref() == Some(parent_id) && item.name == name)
            .cloned()
        {
            return Ok(item);
        }
        let item = RemoteItem {
            id: format!("remote-{}", self.items.len() + 1),
            parent_id: Some(parent_id.into()),
            uri: format!("{}/{}", parent_id, name),
            name: name.into(),
            kind: RemoteItemKind::Folder,
            size: 0,
            content_etag: None,
            metadata_revision: Some(replay_key.into()),
            content_type: "public.folder".into(),
            can_read: true,
            can_write: true,
            can_add_children: true,
            can_trash: true,
            can_delete: true,
            trashed: false,
        };
        self.calls.push(format!("create_folder:{}", replay_key));
        self.items.insert(item.id.clone(), item.clone());
        Ok(item)
    }
    fn create_file(
        &mut self,
        parent_id: &str,
        name: &str,
        content: &[u8],
        replay_key: &str,
    ) -> Result<RemoteItem, CoreError> {
        if let Some(item) = self
            .items
            .values()
            .find(|item| item.parent_id.as_deref() == Some(parent_id) && item.name == name)
            .cloned()
        {
            return Ok(item);
        }
        let item = RemoteItem {
            id: format!("remote-{}", self.items.len() + 1),
            parent_id: Some(parent_id.into()),
            uri: format!("{}/{}", parent_id, name),
            name: name.into(),
            kind: RemoteItemKind::File,
            size: content.len() as u64,
            content_etag: Some(format!("etag-{}", content.len())),
            metadata_revision: Some(replay_key.into()),
            content_type: "public.data".into(),
            can_read: true,
            can_write: true,
            can_add_children: false,
            can_trash: true,
            can_delete: true,
            trashed: false,
        };
        self.calls.push(format!("create_file:{}", replay_key));
        self.items.insert(item.id.clone(), item.clone());
        Ok(item)
    }
    fn modify_file(
        &mut self,
        item_id: &str,
        expected_version: &[u8],
        name: Option<&str>,
        content: Option<&[u8]>,
    ) -> Result<RemoteItem, CoreError> {
        let item = self.items.get_mut(item_id).ok_or(CoreError::NotFound)?;
        if item_version(item) != expected_version {
            return Err(CoreError::VersionConflict);
        }
        if let Some(name) = name {
            item.name = name.into();
        }
        if let Some(content) = content {
            item.size = content.len() as u64;
            item.content_etag = Some(format!("etag-{}", content.len()));
        }
        self.calls.push(format!("modify:{}", item_id));
        Ok(item.clone())
    }
    fn move_item(
        &mut self,
        item_id: &str,
        expected_version: &[u8],
        parent_id: &str,
        name: Option<&str>,
    ) -> Result<RemoteItem, CoreError> {
        let mut item = self.modify_file(item_id, expected_version, name, None)?;
        item.parent_id = Some(parent_id.into());
        self.items.insert(item_id.into(), item.clone());
        Ok(item)
    }
    fn trash_item(
        &mut self,
        item_id: &str,
        expected_version: &[u8],
    ) -> Result<RemoteItem, CoreError> {
        let mut item = self.modify_file(item_id, expected_version, None, None)?;
        item.trashed = true;
        self.items.insert(item_id.into(), item.clone());
        Ok(item)
    }
    fn restore_item(
        &mut self,
        item_id: &str,
        expected_version: &[u8],
        parent_id: &str,
    ) -> Result<RemoteItem, CoreError> {
        let mut item = self.move_item(item_id, expected_version, parent_id, None)?;
        item.trashed = false;
        self.items.insert(item_id.into(), item.clone());
        Ok(item)
    }
    fn delete_item(
        &mut self,
        item_id: &str,
        expected_version: &[u8],
        _recursive: bool,
    ) -> Result<(), CoreError> {
        let item = self.items.get(item_id).ok_or(CoreError::NotFound)?;
        if item_version(item) != expected_version {
            return Err(CoreError::VersionConflict);
        }
        self.calls.push(format!("delete:{}", item_id));
        self.items.remove(item_id);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cloudreve_protocol::{CapabilityState, ProviderCapability};

    fn remote_item(id: &str) -> RemoteItem {
        RemoteItem {
            id: id.into(),
            parent_id: Some("root".into()),
            uri: format!("/{}", id),
            name: id.into(),
            kind: RemoteItemKind::File,
            size: 3,
            content_etag: Some("v1".into()),
            metadata_revision: Some("m1".into()),
            content_type: "public.data".into(),
            can_read: true,
            can_write: true,
            can_add_children: false,
            can_trash: true,
            can_delete: true,
            trashed: false,
        }
    }

    #[test]
    fn health_never_reports_healthy_without_recent_reconciliation() {
        let input = HealthInputs {
            authenticated: true,
            root_available: true,
            scope_valid: true,
            app_running: true,
            valid_anchor: true,
            recently_reconciled: false,
            ..Default::default()
        };
        assert_eq!(reduce_health(&input), HealthState::Reconciling);
        let input = HealthInputs {
            recently_reconciled: true,
            ..input
        };
        assert_eq!(reduce_health(&input), HealthState::Healthy);
    }

    #[test]
    fn incomplete_scan_never_creates_tombstones() {
        let expected = HashSet::from(["a".into(), "b".into()]);
        let seen = HashSet::from(["a".into()]);
        assert!(Reconciliation::tombstone_candidates(
            &expected,
            &seen,
            &HashSet::new(),
            &HashSet::new(),
            true,
            false
        )
        .is_empty());
        assert_eq!(
            Reconciliation::tombstone_candidates(
                &expected,
                &seen,
                &HashSet::new(),
                &HashSet::new(),
                true,
                true
            ),
            vec!["b"]
        );
    }

    #[test]
    fn stale_modify_is_a_conflict_and_not_a_retry() {
        let item = remote_item("one");
        let mut remote = InMemoryRemote {
            items: HashMap::from([(item.id.clone(), item.clone())]),
            calls: Vec::new(),
        };
        let mut store = StateStore::open_in_memory().unwrap();
        let intent = OperationIntent {
            operation_id: Uuid::new_v4(),
            replay_key: "modify-1".into(),
            kind: OperationKind::Modify,
            item_id: None,
            expected_version: Some(b"old".to_vec()),
            changed_fields: vec!["contents".into()],
            source_generation: 1,
        };
        let result = MutationCoordinator {
            store: &mut store,
            remote: &mut remote,
        }
        .modify_file(&intent, "one", None, Some(b"new"));
        assert_eq!(result, Err(CoreError::VersionConflict));
        assert!(remote.calls.is_empty());
    }

    #[test]
    fn local_echo_requires_multiple_evidence_points() {
        let item = remote_item("one");
        let evidence = EchoEvidence {
            remote_id: "one".into(),
            operation_id: Uuid::new_v4(),
            expected_parent: Some("root".into()),
            expected_name: Some("one".into()),
            expected_version: Some(b"v1".to_vec()),
        };
        assert!(is_local_echo(&evidence, &item));
        let mut changed = item.clone();
        changed.name = "other".into();
        assert!(!is_local_echo(&evidence, &changed));
        let mut moved = item.clone();
        moved.parent_id = Some("other".into());
        assert!(!is_local_echo(&evidence, &moved));
    }

    #[test]
    fn create_replay_uses_a_stable_local_item_identity() {
        let mut remote = InMemoryRemote::default();
        let mut store = StateStore::open_in_memory().unwrap();
        let intent = OperationIntent {
            operation_id: Uuid::new_v4(),
            replay_key: "template-create".into(),
            kind: OperationKind::Create,
            item_id: None,
            expected_version: None,
            changed_fields: vec![],
            source_generation: 1,
        };
        let first = MutationCoordinator {
            store: &mut store,
            remote: &mut remote,
        }
        .create_file(&intent, "root", "file.txt", b"one")
        .unwrap();
        let second = MutationCoordinator {
            store: &mut store,
            remote: &mut remote,
        }
        .create_file(&intent, "root", "file.txt", b"one")
        .unwrap();
        assert_eq!(first.id, second.id);
        assert_eq!(store.list_item_ids(None).unwrap().len(), 1);
        assert_eq!(
            remote
                .calls
                .iter()
                .filter(|call| call.starts_with("create_file:"))
                .count(),
            1
        );
    }

    #[test]
    fn provider_unknown_is_fail_closed() {
        let mut snapshot = CapabilitySnapshot::read_only_default();
        snapshot.stable_item_identity = CapabilityState::Verified;
        snapshot.stable_root_identity = CapabilityState::Verified;
        snapshot.conditional_content_write = CapabilityState::Verified;
        snapshot.idempotent_create = CapabilityState::Verified;
        snapshot.providers.push(ProviderCapability {
            provider: "s3".into(),
            read: CapabilityState::Verified,
            write: CapabilityState::Unverified,
            resumable: CapabilityState::Unverified,
            zero_byte: CapabilityState::Unverified,
            crypto: CapabilityState::Unverified,
        });
        assert!(!provider_can_write(&snapshot, "s3"));
        assert!(!provider_can_write(&snapshot, "unknown"));
    }
}
