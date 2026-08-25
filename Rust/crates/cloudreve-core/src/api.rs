use crate::CoreError;
use bytes::Bytes;
use cloudreve_protocol::{normalize_origin, ApiEnvelope, FileEventDto, FileUrlDto, RemoteFileDto, RemoteItem, RemoteListDto, ServerEvent, SseEvent, SseParser, UserDto, UploadCredentialDto};
use futures_util::{Stream, StreamExt};
use reqwest::{Client as HttpClient, Method, StatusCode, Url};
use serde::de::DeserializeOwned;
use serde_json::json;
use std::{collections::VecDeque, pin::Pin, sync::Arc};
use tokio::{io::{AsyncWrite, AsyncWriteExt}, sync::RwLock};

const API_PREFIX: &str = "api/v4";
const CLIENT_HEADER: &str = "X-Cr-Client-Id";

#[derive(Clone)]
pub struct CloudreveHttpClient {
    base_url: Url,
    http: HttpClient,
    access_token: Arc<RwLock<Option<String>>>,
    client_id: String,
}

impl CloudreveHttpClient {
    pub fn new(origin: &str, client_id: impl Into<String>, allow_loopback_http: bool) -> Result<Self, CoreError> {
        let normalized = normalize_origin(origin, allow_loopback_http).map_err(|_| CoreError::UnsupportedServer)?;
        let mut base_url = Url::parse(&format!("{normalized}/")).map_err(|_| CoreError::UnsupportedServer)?;
        let mut path = base_url.path().trim_end_matches('/').to_owned();
        path.push('/');
        base_url.set_path(&path);
        let http = HttpClient::builder()
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(std::time::Duration::from_secs(10))
            .timeout(std::time::Duration::from_secs(60))
            .build()
            .map_err(|_| CoreError::Network)?;
        Ok(Self { base_url, http, access_token: Arc::new(RwLock::new(None)), client_id: client_id.into() })
    }

    pub async fn set_access_token(&self, token: Option<String>) { *self.access_token.write().await = token; }

    pub fn origin(&self) -> &Url { &self.base_url }

    fn api_url(&self, path: &str) -> Result<Url, CoreError> {
        self.base_url.join(&format!("{API_PREFIX}/{}", path.trim_start_matches('/'))).map_err(|_| CoreError::UnsupportedServer)
    }

    async fn request<T: DeserializeOwned>(&self, method: Method, path: &str, query: &[(&str, String)], body: Option<serde_json::Value>, authenticated: bool) -> Result<T, CoreError> {
        let url = self.api_url(path)?;
        let mut builder = self.http.request(method, url).query(query).header(CLIENT_HEADER, &self.client_id).header("Accept", "application/json");
        if authenticated {
            if let Some(token) = self.access_token.read().await.clone() { builder = builder.bearer_auth(token); }
            else { return Err(CoreError::Authentication); }
        }
        if let Some(body) = body { builder = builder.json(&body); }
        let response = builder.send().await.map_err(|_| CoreError::Network)?;
        decode_response(response).await
    }

    pub async fn validate_site(&self) -> Result<cloudreve_protocol::SiteConfigDto, CoreError> {
        self.request(Method::GET, "site/config/login", &[], None, false).await
    }

    pub async fn user_me(&self) -> Result<UserDto, CoreError> { self.request(Method::GET, "user/me", &[], None, true).await }

    pub async fn get_item_by_id(&self, id: &str) -> Result<RemoteItem, CoreError> {
        let file: RemoteFileDto = self.request(Method::GET, "file/info", &[("id", id.into()), ("extended", "true".into())], None, true).await?;
        Ok(file.to_remote_item(None))
    }

    pub async fn get_item_by_uri(&self, uri: &str) -> Result<RemoteItem, CoreError> {
        let file: RemoteFileDto = self.request(Method::GET, "file/info", &[("uri", uri.into()), ("extended", "true".into())], None, true).await?;
        Ok(file.to_remote_item(None))
    }

    pub async fn list_children_page(&self, uri: &str, page: Option<i32>, next_token: Option<&str>, page_size: i32) -> Result<RemoteListDto, CoreError> {
        let mut query = vec![
            ("uri", uri.to_owned()),
            ("page_size", page_size.clamp(1, 500).to_string()),
            ("order_by", "name".into()),
            ("order_direction", "asc".into()),
        ];
        if let Some(page) = page { query.push(("page", page.to_string())); }
        if let Some(next_token) = next_token { query.push(("next_page_token", next_token.to_owned())); }
        self.request(Method::GET, "file", &query.iter().map(|(key, value)| (*key, value.clone())).collect::<Vec<_>>(), None, true).await
    }

    pub async fn list_children_all(&self, uri: &str, page_size: i32) -> Result<Vec<RemoteItem>, CoreError> {
        let mut page = None;
        let mut token = None;
        let mut output = Vec::new();
        loop {
            let response = self.list_children_page(uri, page, token.as_deref(), page_size).await?;
            let count = response.files.len();
            output.extend(response.files.into_iter().map(|file| file.to_remote_item(None)));
            if let Some(next) = response.pagination.next_token {
                token = Some(next);
                page = None;
                continue;
            }
            if let Some(total) = response.pagination.total_items {
                let current_page = response.pagination.page.max(1) as i64;
                let size = response.pagination.page_size.max(1) as i64;
                if current_page * size < total && count > 0 { page = Some(current_page as i32 + 1); token = None; continue; }
            }
            break;
        }
        output.sort_by(|left, right| left.name.to_lowercase().cmp(&right.name.to_lowercase()).then(left.id.cmp(&right.id)));
        Ok(output)
    }

    pub async fn fetch_contents_to<W: AsyncWrite + Unpin>(&self, item_uri: &str, writer: &mut W) -> Result<u64, CoreError> {
        let urls: FileUrlDto = self.request(Method::POST, "file/url", &[], Some(json!({ "uris": [item_uri], "download": true, "redirect": false })), true).await?;
        let target = urls.urls.first().ok_or(CoreError::NotFound)?.url.parse::<Url>().map_err(|_| CoreError::Network)?;
        let response = self.http.get(target).send().await.map_err(|_| CoreError::Network)?;
        if !response.status().is_success() { return Err(CoreError::Network); }
        let mut stream = response.bytes_stream();
        let mut total = 0;
        while let Some(chunk) = stream.next().await {
            let chunk = chunk.map_err(|_| CoreError::Network)?;
            writer.write_all(&chunk).await.map_err(|_| CoreError::IntegrityFailure)?;
            total += chunk.len() as u64;
        }
        writer.flush().await.map_err(|_| CoreError::IntegrityFailure)?;
        Ok(total)
    }

    pub async fn fetch_contents(&self, item_uri: &str) -> Result<Bytes, CoreError> {
        let mut data = Vec::new();
        self.fetch_contents_to(item_uri, &mut data).await?;
        Ok(Bytes::from(data))
    }

    pub async fn create_item(&self, uri: &str, kind: &str) -> Result<RemoteItem, CoreError> {
        let file: RemoteFileDto = self.request(Method::POST, "file/create", &[], Some(json!({ "uri": uri, "type": kind, "err_on_conflict": true })), true).await?;
        Ok(file.to_remote_item(None))
    }

    pub async fn update_content(&self, uri: &str, previous: Option<&str>, content: Bytes) -> Result<RemoteItem, CoreError> {
        let mut query = vec![("uri", uri.to_owned())];
        if let Some(previous) = previous { query.push(("previous", previous.to_owned())); }
        let url = self.api_url("file/content")?;
        let mut request = self.http.put(url).query(&query).header(CLIENT_HEADER, &self.client_id).header("Content-Type", "application/octet-stream");
        request = request.bearer_auth(self.access_token.read().await.clone().ok_or(CoreError::Authentication)?);
        let response = request.body(content).send().await.map_err(|_| CoreError::Network)?;
        let file: RemoteFileDto = decode_response(response).await?;
        Ok(file.to_remote_item(None))
    }

    pub async fn rename_item(&self, uri: &str, name: &str) -> Result<RemoteItem, CoreError> {
        let file: RemoteFileDto = self.request(Method::POST, "file/rename", &[], Some(json!({ "uri": uri, "new_name": name })), true).await?;
        Ok(file.to_remote_item(None))
    }

    pub async fn move_item(&self, uri: &str, destination: &str, copy: bool) -> Result<(), CoreError> {
        let _: serde_json::Value = self.request(Method::POST, "file/move", &[], Some(json!({ "uris": [uri], "dst": destination, "copy": copy })), true).await?;
        Ok(())
    }

    pub async fn trash_item(&self, uri: &str) -> Result<(), CoreError> {
        let _: serde_json::Value = self.request(Method::DELETE, "file", &[], Some(json!({ "uris": [uri], "skip_soft_delete": false })), true).await?;
        Ok(())
    }

    pub async fn restore_item(&self, uri: &str) -> Result<(), CoreError> {
        let _: serde_json::Value = self.request(Method::POST, "file/restore", &[], Some(json!({ "uris": [uri] })), true).await?;
        Ok(())
    }

    pub async fn delete_item(&self, uri: &str, recursive: bool) -> Result<(), CoreError> {
        let _: serde_json::Value = self.request(Method::DELETE, "file", &[], Some(json!({ "uris": [uri], "skip_soft_delete": true, "recursive": recursive })), true).await?;
        Ok(())
    }

    pub async fn create_upload_session(&self, uri: &str, size: u64) -> Result<UploadCredentialDto, CoreError> {
        self.request(Method::PUT, "file/upload", &[], Some(json!({ "uri": uri, "size": size })), true).await
    }

    pub async fn upload_part(&self, session_id: &str, part: u32, content: Bytes) -> Result<(), CoreError> {
        let url = self.api_url(&format!("file/upload/{session_id}/{part}"))?;
        let token = self.access_token.read().await.clone().ok_or(CoreError::Authentication)?;
        let response = self.http.post(url).header(CLIENT_HEADER, &self.client_id).bearer_auth(token).header("Content-Type", "application/octet-stream").body(content).send().await.map_err(|_| CoreError::Network)?;
        let _: serde_json::Value = decode_response(response).await?;
        Ok(())
    }

    pub async fn complete_upload(&self, policy: &str, session_id: &str, secret: &str) -> Result<(), CoreError> {
        let _: serde_json::Value = self.request(Method::GET, &format!("callback/{policy}/{session_id}/{secret}"), &[], None, false).await?;
        Ok(())
    }

    pub async fn subscribe_events(&self, uri: &str, client_id: &str) -> Result<SseSubscription, CoreError> {
        let url = self.api_url("file/events")?;
        let token = self.access_token.read().await.clone().ok_or(CoreError::Authentication)?;
        let response = self.http.get(url).query(&[("uri", uri)]).header(CLIENT_HEADER, client_id).bearer_auth(token).header("Accept", "text/event-stream").send().await.map_err(|_| CoreError::Network)?;
        if response.status() != StatusCode::OK || !response.headers().get(reqwest::header::CONTENT_TYPE).and_then(|value| value.to_str().ok()).unwrap_or("").contains("text/event-stream") { return Err(CoreError::Network); }
        Ok(SseSubscription { stream: Box::pin(response.bytes_stream()), parser: SseParser::default(), pending: VecDeque::new() })
    }
}

pub struct SseSubscription {
    stream: Pin<Box<dyn Stream<Item = Result<Bytes, reqwest::Error>> + Send>>,
    parser: SseParser,
    pending: VecDeque<SseEvent>,
}

impl SseSubscription {
    pub async fn next_event(&mut self) -> Result<Option<ServerEvent>, CoreError> {
        if let Some(event) = self.pending.pop_front() {
            return Ok(Some(map_sse_event(event)));
        }
        loop {
            let Some(chunk) = self.stream.next().await else {
                self.pending.extend(self.parser.finish());
                return Ok(self.pending.pop_front().map(map_sse_event));
            };
            let chunk = chunk.map_err(|_| CoreError::Network)?;
            let events = self.parser.push(&chunk).map_err(|_| CoreError::Network)?;
            self.pending.extend(events);
            if let Some(event) = self.pending.pop_front() {
                return Ok(Some(map_sse_event(event)));
            }
        }
    }

    pub fn finish(&mut self) -> Result<Vec<ServerEvent>, CoreError> {
        self.pending.extend(self.parser.finish());
        Ok(self.pending.drain(..).map(map_sse_event).collect())
    }
}

fn map_sse_event(event: SseEvent) -> ServerEvent {
    match event.event.as_deref() {
        Some("subscribed") => ServerEvent::Subscribed,
        Some("resumed") => ServerEvent::Resumed,
        Some("keep-alive") | Some("keepalive") => ServerEvent::KeepAlive,
        Some("reconnect-required") => ServerEvent::ReconnectRequired,
        Some("event") => serde_json::from_str::<Vec<FileEventDto>>(&event.data).map(ServerEvent::Files).or_else(|_| serde_json::from_str::<FileEventDto>(&event.data).map(|value| ServerEvent::Files(vec![value]))).unwrap_or(ServerEvent::Unknown),
        _ => ServerEvent::Unknown,
    }
}

async fn decode_response<T: DeserializeOwned>(response: reqwest::Response) -> Result<T, CoreError> {
    let status = response.status();
    let body = response.json::<ApiEnvelope<T>>().await.map_err(|_| CoreError::Network)?;
    if status == StatusCode::UNAUTHORIZED || matches!(body.code, 401 | 40020 | 40089) { return Err(CoreError::Authentication); }
    match body.into_result() {
        Ok(value) => Ok(value),
        Err(error) => Err(map_api_error(error.code)),
    }
}

fn map_api_error(code: i32) -> CoreError {
    match code {
        401 | 40020 | 40089 => CoreError::Authentication,
        40006 | 40007 | 40008 => CoreError::PermissionDenied,
        40009 | 40010 => CoreError::NotFound,
        40012 | 40013 => CoreError::NameCollision,
        40014 | 40015 => CoreError::VersionConflict,
        40030 => CoreError::QuotaExceeded,
        _ => CoreError::UnknownOutcome,
    }
}
