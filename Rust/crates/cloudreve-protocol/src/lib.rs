//! Platform-neutral Cloudreve protocol and consistency primitives.
//!
//! This crate intentionally contains no Apple or Windows types.  It is the
//! contract boundary consumed by the Rust core and the narrow FFI layer.

use base64::Engine;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::VecDeque;
use thiserror::Error;
use url::Url;
use uuid::Uuid;

pub const PROTOCOL_ABI_VERSION: u32 = 1;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ApiEnvelope<T> {
    pub code: i32,
    #[serde(default)]
    pub msg: String,
    pub data: Option<T>,
}

impl<T> ApiEnvelope<T> {
    pub fn into_result(self) -> Result<T, ApiError> {
        if self.code != 0 {
            return Err(ApiError {
                code: self.code,
                message: self.msg,
            });
        }
        self.data.ok_or_else(|| ApiError {
            code: -1,
            message: "successful response did not include data".into(),
        })
    }

    pub fn into_unit(self) -> Result<(), ApiError> {
        if self.code != 0 {
            return Err(ApiError {
                code: self.code,
                message: self.msg,
            });
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ApiError {
    pub code: i32,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq, Eq)]
pub struct Pagination {
    #[serde(default)]
    pub page: i32,
    #[serde(default)]
    pub page_size: i32,
    pub total_items: Option<i64>,
    pub next_token: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct NavigatorProps {
    pub max_page_size: i32,
    #[serde(default)]
    pub capability: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct RemoteFileDto {
    #[serde(rename = "type")]
    pub file_type: i32,
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub permission: Option<String>,
    #[serde(default)]
    pub created_at: String,
    #[serde(default)]
    pub updated_at: String,
    #[serde(default)]
    pub size: i64,
    pub path: String,
    #[serde(default)]
    pub shared: Option<bool>,
    #[serde(default)]
    pub capability: Option<String>,
    #[serde(default)]
    pub owned: Option<bool>,
    #[serde(default)]
    pub primary_entity: Option<String>,
    #[serde(default)]
    pub folder_summary: Option<FolderSummaryDto>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct FolderSummaryDto {
    #[serde(default)]
    pub files: i32,
    #[serde(default)]
    pub folders: i32,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct RemoteListDto {
    #[serde(default)]
    pub files: Vec<RemoteFileDto>,
    #[serde(default)]
    pub pagination: Pagination,
    #[serde(default)]
    pub props: NavigatorProps,
    pub parent: Option<RemoteFileDto>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct UserDto {
    pub id: String,
    #[serde(default)]
    pub nickname: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct TokenDto {
    pub access_token: String,
    pub refresh_token: String,
    pub access_expires: String,
    pub refresh_expires: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct SiteConfigDto {
    #[serde(default)]
    pub version: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub icon: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct StoragePolicyDto {
    pub id: String,
    #[serde(rename = "type")]
    pub policy_type: String,
    #[serde(default)]
    pub chunk_concurrency: Option<i32>,
    #[serde(default)]
    pub encryption: Option<bool>,
    #[serde(default)]
    pub streaming_encryption: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct UploadCredentialDto {
    pub session_id: String,
    pub expires: i64,
    pub chunk_size: i64,
    #[serde(default)]
    pub upload_urls: Option<Vec<String>>,
    #[serde(default)]
    pub credential: String,
    #[serde(default)]
    pub upload_id: String,
    #[serde(default)]
    pub callback_secret: String,
    #[serde(rename = "completeURL", default)]
    pub complete_url: Option<String>,
    #[serde(default)]
    pub storage_policy: Option<StoragePolicyDto>,
    pub uri: String,
    #[serde(default)]
    pub mime_type: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct FileUrlDto {
    pub urls: Vec<EntityUrlDto>,
    pub expires: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct EntityUrlDto {
    pub url: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq, Eq)]
pub struct FileEventDto {
    #[serde(rename = "type")]
    pub event_type: String,
    #[serde(default, alias = "file_id")]
    pub id: Option<String>,
    #[serde(default)]
    pub from: String,
    #[serde(default)]
    pub to: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ServerEvent {
    Subscribed,
    Resumed,
    KeepAlive,
    ReconnectRequired,
    Files(Vec<FileEventDto>),
    Unknown,
}

impl RemoteFileDto {
    pub fn to_remote_item(&self, parent_id: Option<String>) -> RemoteItem {
        let is_folder = self.file_type == 1;
        let can_read = self
            .permission
            .as_deref()
            .map(|value| value.contains('r'))
            .unwrap_or(true);
        let can_write = self
            .capability
            .as_deref()
            .map(|value| value.contains('w'))
            .unwrap_or(false)
            && can_read;
        let content_version = self
            .primary_entity
            .clone()
            .unwrap_or_else(|| self.updated_at.clone());
        RemoteItem {
            id: self.id.clone(),
            parent_id,
            uri: self.path.clone(),
            name: self.name.clone(),
            kind: if is_folder {
                RemoteItemKind::Folder
            } else {
                RemoteItemKind::File
            },
            size: self.size.max(0) as u64,
            content_etag: Some(content_version),
            metadata_revision: Some(self.updated_at.clone()),
            content_type: if is_folder {
                "public.folder".into()
            } else {
                "public.data".into()
            },
            can_read,
            can_write,
            can_add_children: is_folder && can_write,
            can_trash: can_read
                && self
                    .capability
                    .as_deref()
                    .map(|value| value.contains('d'))
                    .unwrap_or(false),
            can_delete: can_read
                && self
                    .capability
                    .as_deref()
                    .map(|value| value.contains('d'))
                    .unwrap_or(false),
            trashed: false,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RemoteItemKind {
    File,
    Folder,
    Symlink,
    Unsupported,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RemoteItem {
    pub id: String,
    pub parent_id: Option<String>,
    pub uri: String,
    pub name: String,
    pub kind: RemoteItemKind,
    pub size: u64,
    pub content_etag: Option<String>,
    pub metadata_revision: Option<String>,
    pub content_type: String,
    pub can_read: bool,
    pub can_write: bool,
    pub can_add_children: bool,
    pub can_trash: bool,
    pub can_delete: bool,
    pub trashed: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CapabilityState {
    Verified,
    Unsupported,
    Unverified,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProviderCapability {
    pub provider: String,
    pub read: CapabilityState,
    pub write: CapabilityState,
    pub resumable: CapabilityState,
    pub zero_byte: CapabilityState,
    pub crypto: CapabilityState,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CapabilitySnapshot {
    pub revision: u64,
    pub cloudreve_version: Option<String>,
    pub stable_item_identity: CapabilityState,
    pub stable_root_identity: CapabilityState,
    pub conditional_content_write: CapabilityState,
    pub idempotent_create: CapabilityState,
    pub trash_restore: CapabilityState,
    pub sse: CapabilityState,
    pub providers: Vec<ProviderCapability>,
}

impl CapabilitySnapshot {
    pub fn read_only_default() -> Self {
        Self {
            revision: 0,
            cloudreve_version: None,
            stable_item_identity: CapabilityState::Unverified,
            stable_root_identity: CapabilityState::Unverified,
            conditional_content_write: CapabilityState::Unsupported,
            idempotent_create: CapabilityState::Unsupported,
            trash_restore: CapabilityState::Unsupported,
            sse: CapabilityState::Unverified,
            providers: Vec::new(),
        }
    }

    pub fn allows_write(&self) -> bool {
        self.stable_item_identity == CapabilityState::Verified
            && self.stable_root_identity == CapabilityState::Verified
            && self.conditional_content_write == CapabilityState::Verified
            && self.idempotent_create == CapabilityState::Verified
    }

    pub fn provider(&self, name: &str) -> Option<&ProviderCapability> {
        self.providers
            .iter()
            .find(|provider| provider.provider == name)
    }
}

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum ProtocolError {
    #[error("origin must use HTTPS")]
    InsecureOrigin,
    #[error("origin is invalid: {0}")]
    InvalidOrigin(String),
    #[error("identifier is invalid")]
    InvalidIdentifier,
    #[error("scope is invalid")]
    InvalidScope,
    #[error("encoded value does not fit in the File Provider page limit")]
    ValueTooLarge,
    #[error("anchor belongs to a different domain or epoch")]
    AnchorMismatch,
    #[error("SSE frame exceeds the configured buffer limit")]
    SseFrameTooLarge,
}

pub fn normalize_origin(origin: &str, allow_loopback_http: bool) -> Result<String, ProtocolError> {
    let trimmed = origin.trim();
    let mut url =
        Url::parse(trimmed).map_err(|error| ProtocolError::InvalidOrigin(error.to_string()))?;
    let is_loopback = matches!(url.host_str(), Some("localhost" | "127.0.0.1" | "::1"));
    if url.scheme() != "https" && !(allow_loopback_http && url.scheme() == "http" && is_loopback) {
        return Err(ProtocolError::InsecureOrigin);
    }
    if url.username() != ""
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(ProtocolError::InvalidOrigin(
            "credentials, query and fragment are not allowed".into(),
        ));
    }
    url.set_query(None);
    url.set_fragment(None);
    let path = url.path().trim_end_matches('/').to_owned();
    url.set_path(if path.is_empty() { "/" } else { &path });
    Ok(url.to_string().trim_end_matches('/').to_string())
}

pub fn canonical_scope(
    origin: &str,
    account_id: &str,
    remote_uri: &str,
) -> Result<String, ProtocolError> {
    let origin = normalize_origin(origin, false)?;
    if account_id.is_empty() || account_id.contains('\0') {
        return Err(ProtocolError::InvalidScope);
    }
    let mut path = if remote_uri.trim_start().starts_with("cloudreve://") {
        let parsed = Url::parse(remote_uri.trim()).map_err(|_| ProtocolError::InvalidScope)?;
        if parsed.host_str() != Some("my")
            || parsed.username() != account_id
            || parsed.password().is_some()
            || parsed.query().is_some()
            || parsed.fragment().is_some()
        {
            return Err(ProtocolError::InvalidScope);
        }
        parsed.path().to_owned()
    } else {
        remote_uri.trim().replace('\\', "/")
    };
    if !path.starts_with('/') {
        path.insert(0, '/');
    }
    let segments: Vec<String> = path
        .split('/')
        .filter(|segment| !segment.is_empty() && *segment != ".")
        .try_fold(Vec::new(), |mut result, segment| {
            if segment == ".." {
                return Err(ProtocolError::InvalidScope);
            }
            result.push(segment.to_string());
            Ok(result)
        })?;
    let path = format!("/{}", segments.join("/"));
    Ok(format!("{}\u{0}{}\u{0}{}", origin, account_id, path))
}

pub fn scopes_overlap(left: &str, right: &str) -> bool {
    let left = left.split('\0').collect::<Vec<_>>();
    let right = right.split('\0').collect::<Vec<_>>();
    if left.len() != 3 || right.len() != 3 || left[0] != right[0] || left[1] != right[1] {
        return false;
    }
    let left_path = if left[2] == "/" {
        "/"
    } else {
        left[2].trim_end_matches('/')
    };
    let right_path = if right[2] == "/" {
        "/"
    } else {
        right[2].trim_end_matches('/')
    };
    fn contains(parent: &str, child: &str) -> bool {
        parent == "/" || parent == child || child.starts_with(&(parent.to_string() + "/"))
    }
    contains(left_path, right_path) || contains(right_path, left_path)
}

pub fn validate_local_identifier(value: &str, prefix: &str) -> Result<(), ProtocolError> {
    let expected = format!("{}-", prefix);
    if !value.starts_with(&expected)
        || value.contains('/')
        || value.contains(':')
        || value.contains('@')
        || value.len() != expected.len() + 36
        || Uuid::parse_str(&value[expected.len()..]).is_err()
    {
        return Err(ProtocolError::InvalidIdentifier);
    }
    Ok(())
}

pub fn content_version(primary_entity: &str) -> Vec<u8> {
    digest_parts([primary_entity.as_bytes()])
}

pub fn metadata_version(parts: &[&[u8]]) -> Vec<u8> {
    digest_parts(parts.iter().copied())
}

fn digest_parts<'a, I>(parts: I) -> Vec<u8>
where
    I: IntoIterator<Item = &'a [u8]>,
{
    let mut hasher = Sha256::new();
    for part in parts {
        hasher.update((part.len() as u64).to_be_bytes());
        hasher.update(part);
    }
    hasher.finalize().to_vec()
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PageToken {
    pub version: u8,
    pub domain_id: Uuid,
    pub parent_id: String,
    pub snapshot_generation: u64,
    pub offset: u64,
    pub sort: String,
}

impl PageToken {
    pub fn encode(&self) -> Result<Vec<u8>, ProtocolError> {
        let json = serde_json::to_vec(self).map_err(|_| ProtocolError::ValueTooLarge)?;
        let encoded = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .encode(json)
            .into_bytes();
        if encoded.len() > 500 {
            return Err(ProtocolError::ValueTooLarge);
        }
        Ok(encoded)
    }

    pub fn decode(value: &[u8]) -> Result<Self, ProtocolError> {
        let json = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .decode(value)
            .map_err(|_| ProtocolError::InvalidIdentifier)?;
        serde_json::from_slice(&json).map_err(|_| ProtocolError::InvalidIdentifier)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SyncAnchor {
    pub version: u8,
    pub domain_id: Uuid,
    pub scope: String,
    pub epoch: Uuid,
    pub sequence: u64,
}

impl SyncAnchor {
    pub fn encode(&self) -> Result<Vec<u8>, ProtocolError> {
        let json = serde_json::to_vec(self).map_err(|_| ProtocolError::ValueTooLarge)?;
        let encoded = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .encode(json)
            .into_bytes();
        if encoded.len() > 500 {
            return Err(ProtocolError::ValueTooLarge);
        }
        Ok(encoded)
    }

    pub fn decode(value: &[u8]) -> Result<Self, ProtocolError> {
        let json = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .decode(value)
            .map_err(|_| ProtocolError::AnchorMismatch)?;
        serde_json::from_slice(&json).map_err(|_| ProtocolError::AnchorMismatch)
    }

    pub fn validate(
        &self,
        domain_id: Uuid,
        scope: &str,
        epoch: Uuid,
        min_sequence: u64,
    ) -> Result<(), ProtocolError> {
        if self.domain_id != domain_id
            || self.scope != scope
            || self.epoch != epoch
            || self.sequence < min_sequence
        {
            return Err(ProtocolError::AnchorMismatch);
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SseEvent {
    pub event: Option<String>,
    pub data: String,
    pub id: Option<String>,
}

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum SseError {
    #[error("frame exceeds {0} bytes")]
    FrameTooLarge(usize),
    #[error("SSE frame is not valid UTF-8")]
    InvalidUtf8,
}

/// A strict SSE parser supporting CRLF, LF, comments, multi-line data and
/// event framing. It never stores a complete unbounded stream.
#[derive(Debug, Clone)]
pub struct SseParser {
    buffer: Vec<u8>,
    frame_bytes: usize,
    event: Option<String>,
    id: Option<String>,
    data: Vec<String>,
    max_frame_bytes: usize,
}

impl Default for SseParser {
    fn default() -> Self {
        Self::new(1024 * 1024)
    }
}

impl SseParser {
    pub fn new(max_frame_bytes: usize) -> Self {
        Self {
            buffer: Vec::new(),
            frame_bytes: 0,
            event: None,
            id: None,
            data: Vec::new(),
            max_frame_bytes,
        }
    }

    pub fn push(&mut self, bytes: &[u8]) -> Result<Vec<SseEvent>, SseError> {
        self.buffer.extend_from_slice(bytes);
        let mut events = Vec::new();
        while let Some(position) = find_line_end(&self.buffer) {
            let mut line = self.buffer.drain(..position).collect::<Vec<_>>();
            let newline_len =
                if self.buffer.first() == Some(&b'\r') && self.buffer.get(1) == Some(&b'\n') {
                    2
                } else {
                    1
                };
            self.buffer.drain(..newline_len);
            self.frame_bytes = self.frame_bytes.saturating_add(position + newline_len);
            if self.frame_bytes > self.max_frame_bytes {
                return Err(SseError::FrameTooLarge(self.max_frame_bytes));
            }
            if line.last() == Some(&b'\r') {
                line.pop();
            }
            self.consume_line(&line, &mut events)?;
        }
        if self.frame_bytes.saturating_add(self.buffer.len()) > self.max_frame_bytes {
            return Err(SseError::FrameTooLarge(self.max_frame_bytes));
        }
        Ok(events)
    }

    pub fn finish(&mut self) -> Result<Vec<SseEvent>, SseError> {
        let mut events = Vec::new();
        if !self.buffer.is_empty() {
            let line = std::mem::take(&mut self.buffer);
            self.consume_line(&line, &mut events)?;
        }
        self.flush_event(&mut events);
        Ok(events)
    }

    fn consume_line(&mut self, line: &[u8], events: &mut Vec<SseEvent>) -> Result<(), SseError> {
        if line.is_empty() {
            self.flush_event(events);
            return Ok(());
        }
        if line[0] == b':' {
            return Ok(());
        }
        let text = std::str::from_utf8(line).map_err(|_| SseError::InvalidUtf8)?;
        let (field, value) = text
            .split_once(':')
            .map_or((text.as_ref(), ""), |(field, value)| {
                (field, value.strip_prefix(' ').unwrap_or(value))
            });
        match field {
            "event" => self.event = Some(value.to_owned()),
            "data" => self.data.push(value.to_owned()),
            "id" => self.id = Some(value.to_owned()),
            _ => {}
        }
        Ok(())
    }

    fn flush_event(&mut self, events: &mut Vec<SseEvent>) {
        if self.event.is_some() || self.id.is_some() || !self.data.is_empty() {
            events.push(SseEvent {
                event: self.event.take(),
                id: self.id.take(),
                data: self.data.join("\n"),
            });
        }
        self.data.clear();
        self.frame_bytes = 0;
    }
}

fn find_line_end(buffer: &[u8]) -> Option<usize> {
    for (index, byte) in buffer.iter().enumerate() {
        if *byte == b'\n' {
            return Some(index);
        }
        if *byte == b'\r' {
            // A trailing CR may be the first half of a CRLF split across
            // network chunks, so wait for the next byte before framing it.
            if index + 1 == buffer.len() {
                return None;
            }
            return Some(index);
        }
    }
    None
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Backoff {
    attempt: u32,
    max_delay_ms: u64,
}

impl Backoff {
    pub fn new(max_delay_ms: u64) -> Self {
        Self {
            attempt: 0,
            max_delay_ms,
        }
    }
    pub fn reset(&mut self) {
        self.attempt = 0;
    }
    pub fn next_delay_ms(&mut self, jitter_ms: u64) -> u64 {
        let exponential = 1_000u64.saturating_mul(2u64.saturating_pow(self.attempt.min(16)));
        self.attempt = self.attempt.saturating_add(1);
        let capped = exponential.min(self.max_delay_ms);
        let jitter = if jitter_ms == 0 {
            0
        } else {
            jitter_ms % capped.max(1)
        };
        (capped / 2).saturating_add(jitter.min(capped / 2))
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BoundedQueue<T> {
    values: VecDeque<T>,
    capacity: usize,
}

impl<T> BoundedQueue<T> {
    pub fn new(capacity: usize) -> Self {
        Self {
            values: VecDeque::new(),
            capacity: capacity.max(1),
        }
    }
    pub fn push(&mut self, value: T) {
        if self.values.len() >= self.capacity {
            self.values.pop_front();
        }
        self.values.push_back(value);
    }
    pub fn len(&self) -> usize {
        self.values.len()
    }
    pub fn iter(&self) -> impl Iterator<Item = &T> {
        self.values.iter()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn origin_and_scope_normalization_rejects_unsafe_values() {
        assert_eq!(
            normalize_origin("https://example.com/", false).unwrap(),
            "https://example.com"
        );
        assert!(normalize_origin("http://example.com", false).is_err());
        assert!(canonical_scope("https://example.com", "account", "/a/../b").is_err());
        let root = canonical_scope("https://example.com", "account", "/a").unwrap();
        let child = canonical_scope("https://example.com", "account", "/a/b").unwrap();
        assert!(scopes_overlap(&root, &child));
        let uri_scope =
            canonical_scope("https://example.com", "account", "cloudreve://account@my/a").unwrap();
        assert_eq!(uri_scope, "https://example.com\0account\0/a");
    }

    #[test]
    fn file_event_uses_reference_file_id_and_read_permission_gates_writes() {
        let event: FileEventDto =
            serde_json::from_str(r#"{"type":"modify","file_id":"remote-1","from":"/a","to":"/b"}"#)
                .unwrap();
        assert_eq!(event.id.as_deref(), Some("remote-1"));
        let file = RemoteFileDto {
            id: "remote-1".into(),
            permission: Some("r".into()),
            capability: Some("r".into()),
            ..Default::default()
        };
        let item = file.to_remote_item(None);
        assert!(item.can_read);
        assert!(!item.can_write);
    }

    #[test]
    fn identifiers_are_local_and_strict() {
        let id = format!("cri-{}", Uuid::new_v4());
        assert!(validate_local_identifier(&id, "cri").is_ok());
        assert!(validate_local_identifier("cri-remote/path", "cri").is_err());
    }

    #[test]
    fn page_tokens_are_small_and_do_not_contain_remote_cursor() {
        let token = PageToken {
            version: 1,
            domain_id: Uuid::new_v4(),
            parent_id: "cri-parent".into(),
            snapshot_generation: 4,
            offset: 800,
            sort: "name".into(),
        };
        let encoded = token.encode().unwrap();
        assert!(encoded.len() < 500);
        assert_eq!(PageToken::decode(&encoded).unwrap(), token);
    }

    #[test]
    fn sse_parser_handles_multi_line_and_comments() {
        let mut parser = SseParser::new(1024);
        let events = parser
            .push(
                b": keep\r\nevent: file\r\nid: 7\r\ndata: one\r\ndata: two\r\n\r\n data: ignored\n",
            )
            .unwrap();
        assert_eq!(
            events,
            vec![SseEvent {
                event: Some("file".into()),
                id: Some("7".into()),
                data: "one\ntwo".into()
            }]
        );
    }

    #[test]
    fn sse_parser_preserves_partial_frames_and_multiple_events() {
        let mut parser = SseParser::new(1024);
        assert_eq!(
            parser
                .push(b"event: one\ndata: first\n\neve")
                .unwrap()
                .len(),
            1
        );
        let events = parser.push(b"nt: two\ndata: second\n\n").unwrap();
        assert_eq!(
            events,
            vec![SseEvent {
                event: Some("two".into()),
                id: None,
                data: "second".into()
            }]
        );
        assert!(parser.finish().unwrap().is_empty());
    }

    #[test]
    fn sse_parser_handles_crlf_split_across_chunks() {
        let mut parser = SseParser::new(1024);
        assert!(parser.push(b"event: one\r").unwrap().is_empty());
        let events = parser.push(b"\ndata: first\r\n\r\n").unwrap();
        assert_eq!(
            events,
            vec![SseEvent {
                event: Some("one".into()),
                id: None,
                data: "first".into()
            }]
        );
    }

    #[test]
    fn sse_parser_limits_the_complete_logical_frame() {
        let mut parser = SseParser::new(20);
        assert_eq!(parser.push(b"data: 123456789\n").unwrap().len(), 0);
        assert_eq!(
            parser.push(b"data: 123456789\n"),
            Err(SseError::FrameTooLarge(20))
        );
    }

    #[test]
    fn sync_anchor_encoding_is_bounded() {
        let anchor = SyncAnchor {
            version: 1,
            domain_id: Uuid::new_v4(),
            scope: "x".repeat(500),
            epoch: Uuid::new_v4(),
            sequence: 1,
        };
        assert_eq!(anchor.encode(), Err(ProtocolError::ValueTooLarge));
    }

    #[test]
    fn anchor_mismatch_is_explicit() {
        let anchor = SyncAnchor {
            version: 1,
            domain_id: Uuid::new_v4(),
            scope: "root".into(),
            epoch: Uuid::new_v4(),
            sequence: 5,
        };
        let encoded = anchor.encode().unwrap();
        let decoded = SyncAnchor::decode(&encoded).unwrap();
        assert!(decoded
            .validate(decoded.domain_id, "other", decoded.epoch, 0)
            .is_err());
    }
}
