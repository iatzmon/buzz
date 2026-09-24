//! Private Android FCM HTTP v1 transport for NIP-PL wakes.
//!
//! This is deliberately separate from the public APNs gateway profile. The
//! encrypted lease endpoint is the raw FCM registration token, and the relay
//! owns the Google service-account credential used for the provider request.
//! The only application data sent to FCM is the fixed `buzz_wake=1` signal.

use std::{
    path::Path,
    sync::Arc,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use futures_util::StreamExt;
use jsonwebtoken::{encode, Algorithm, EncodingKey, Header};
use serde::{Deserialize, Serialize};
use tokio::sync::Mutex;

/// NIP-PL app-profile identifier for the private Android FCM route.
pub const APP_PROFILE: &str = "buzz-android-fcm";
/// NIP-PL transport identifier selected by [`APP_PROFILE`].
pub const TRANSPORT: &str = "fcm";
const TOKEN_URI: &str = "https://oauth2.googleapis.com/token";
const FCM_ORIGIN: &str = "https://fcm.googleapis.com";
const OAUTH_SCOPE: &str = "https://www.googleapis.com/auth/firebase.messaging";
const TOKEN_SKEW: Duration = Duration::from_secs(60);
const MAX_RESPONSE_BYTES: usize = 16 * 1024;
const MAX_TOKEN_BYTES: usize = 4096;
const MAX_ACCESS_TOKEN_BYTES: usize = 16 * 1024;
const FCM_TTL: &str = "3600s";

/// Result of one provider request, reduced to the relay's delivery policy.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeliveryResult {
    /// FCM accepted the wake.
    Accepted,
    /// FCM permanently rejected this registration token.
    InvalidEndpoint,
    /// The request should remain in the durable outbox for retry.
    Retry,
    /// The request was a terminal provider error that is not evidence that
    /// the endpoint is invalid.
    Failed,
}

#[derive(Debug, Deserialize)]
struct ServiceAccount {
    project_id: String,
    client_email: String,
    private_key: String,
    token_uri: Option<String>,
}

#[derive(Debug, Serialize)]
struct JwtClaims<'a> {
    iss: &'a str,
    scope: &'a str,
    aud: &'a str,
    iat: u64,
    exp: u64,
}

#[derive(Debug, Deserialize)]
struct TokenResponse {
    access_token: String,
    expires_in: u64,
}

#[derive(Debug, Deserialize)]
struct FcmErrorEnvelope {
    error: Option<FcmErrorBody>,
}

#[derive(Debug, Deserialize)]
struct FcmErrorBody {
    details: Option<Vec<FcmErrorDetail>>,
}

#[derive(Debug, Deserialize)]
struct FcmErrorDetail {
    #[serde(rename = "@type")]
    detail_type: Option<String>,
    #[serde(rename = "errorCode")]
    error_code: Option<String>,
    #[serde(rename = "fieldViolations")]
    field_violations: Option<Vec<FcmFieldViolation>>,
}

#[derive(Debug, Deserialize)]
struct FcmFieldViolation {
    field: Option<String>,
}

struct CachedToken {
    value: String,
    expires_at: Instant,
}

/// Loaded service-account signer and short-lived OAuth token cache.
pub struct FcmClient {
    project_id: String,
    client_email: String,
    signing_key: EncodingKey,
    access_token: Mutex<Option<CachedToken>>,
}

impl std::fmt::Debug for FcmClient {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("FcmClient")
            .field("credentials", &"[REDACTED]")
            .finish()
    }
}

impl FcmClient {
    /// Load a Google service-account JSON file without exposing its contents in
    /// an error or log message. The file is deployment secret material.
    pub fn from_file(path: &Path) -> Result<Arc<Self>, String> {
        let bytes = std::fs::read(path)
            .map_err(|_| "unable to read Android FCM service-account file".to_string())?;
        let account: ServiceAccount = serde_json::from_slice(&bytes)
            .map_err(|_| "invalid Android FCM service-account JSON".to_string())?;
        if account.project_id.is_empty()
            || account.project_id.len() > 128
            || !account
                .project_id
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        {
            return Err("invalid Android FCM project id".to_string());
        }
        if account.client_email.is_empty() || account.client_email.len() > 512 {
            return Err("invalid Android FCM client email".to_string());
        }
        if account
            .token_uri
            .as_deref()
            .is_some_and(|uri| uri != TOKEN_URI)
        {
            return Err("Android FCM service-account token URI is not allowed".to_string());
        }
        let signing_key = EncodingKey::from_rsa_pem(account.private_key.as_bytes())
            .map_err(|_| "invalid Android FCM service-account private key".to_string())?;
        Ok(Arc::new(Self {
            project_id: account.project_id,
            client_email: account.client_email,
            signing_key,
            access_token: Mutex::new(None),
        }))
    }

    /// Deliver the fixed reconnect wake to one raw FCM registration token.
    pub async fn deliver(&self, http: &reqwest::Client, token: &str) -> DeliveryResult {
        if token.is_empty() || token.len() > MAX_TOKEN_BYTES {
            return DeliveryResult::InvalidEndpoint;
        }
        let bearer = match self.access_token(http).await {
            Ok(token) => token,
            Err(_) => return DeliveryResult::Retry,
        };
        let url = format!("{FCM_ORIGIN}/v1/projects/{}/messages:send", self.project_id);
        let response = http
            .post(url)
            .bearer_auth(bearer.as_str())
            .header(reqwest::header::CONTENT_TYPE, "application/json")
            .json(&fcm_message(token))
            .send()
            .await;
        let Ok(response) = response else {
            return DeliveryResult::Retry;
        };
        let status = response.status();
        // Read only to classify the closed provider error schema. Never log or
        // return this body because provider diagnostics can contain endpoint
        // material and credentials-adjacent details.
        let body = match bounded_response_body(response).await {
            Ok(body) => body,
            Err(()) => {
                if status == reqwest::StatusCode::UNAUTHORIZED {
                    self.invalidate_access_token(&bearer).await;
                }
                return DeliveryResult::Retry;
            }
        };
        let result = classify_response(status, &body);
        if status == reqwest::StatusCode::UNAUTHORIZED {
            self.invalidate_access_token(&bearer).await;
        }
        result
    }

    async fn access_token(&self, http: &reqwest::Client) -> Result<String, ()> {
        let mut cache = self.access_token.lock().await;
        if let Some(cached) = cache.as_ref() {
            if cached.expires_at > Instant::now() {
                return Ok(cached.value.clone());
            }
        }
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| ())?
            .as_secs();
        let claims = JwtClaims {
            iss: &self.client_email,
            scope: OAUTH_SCOPE,
            aud: TOKEN_URI,
            iat: now,
            exp: now.checked_add(3600).ok_or(())?,
        };
        let assertion =
            encode(&Header::new(Algorithm::RS256), &claims, &self.signing_key).map_err(|_| ())?;
        let form_body = url::form_urlencoded::Serializer::new(String::new())
            .append_pair("grant_type", "urn:ietf:params:oauth:grant-type:jwt-bearer")
            .append_pair("assertion", &assertion)
            .finish();
        let response = http
            .post(TOKEN_URI)
            .header(
                reqwest::header::CONTENT_TYPE,
                "application/x-www-form-urlencoded",
            )
            .body(form_body)
            .send()
            .await
            .map_err(|_| ())?;
        if !response.status().is_success() {
            return Err(());
        }
        let body = bounded_response_body(response).await.map_err(|_| ())?;
        let response: TokenResponse = serde_json::from_slice(&body).map_err(|_| ())?;
        if response.access_token.is_empty()
            || response.access_token.len() > MAX_ACCESS_TOKEN_BYTES
            || response.expires_in == 0
        {
            return Err(());
        }
        let lifetime =
            Duration::from_secs(response.expires_in.min(3600)).saturating_sub(TOKEN_SKEW);
        let cached = CachedToken {
            value: response.access_token,
            expires_at: Instant::now() + lifetime,
        };
        let value = cached.value.clone();
        *cache = Some(cached);
        Ok(value)
    }

    async fn invalidate_access_token(&self, rejected: &str) {
        let mut cache = self.access_token.lock().await;
        if cache
            .as_ref()
            .is_some_and(|cached| cached.value == rejected)
        {
            *cache = None;
        }
    }
}

/// Exact FCM request data. Destination routing is outside the application
/// body; no event, lease, channel, URL, or ciphertext is serialized here.
fn fcm_message(token: &str) -> serde_json::Value {
    serde_json::json!({
        "message": {
            "token": token,
            "android": {"priority": "HIGH", "ttl": FCM_TTL},
            "data": {"buzz_wake": "1"}
        }
    })
}

async fn bounded_response_body(response: reqwest::Response) -> Result<Vec<u8>, ()> {
    let mut stream = response.bytes_stream();
    let mut body = Vec::new();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|_| ())?;
        let new_len = body.len().checked_add(chunk.len()).ok_or(())?;
        if new_len > MAX_RESPONSE_BYTES {
            return Err(());
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

fn classify_response(status: reqwest::StatusCode, body: &[u8]) -> DeliveryResult {
    if status.is_success() {
        return DeliveryResult::Accepted;
    }
    let error = serde_json::from_slice::<FcmErrorEnvelope>(body)
        .ok()
        .and_then(|envelope| envelope.error);
    let invalid_token = error.as_ref().is_some_and(|error| {
        error.details.as_ref().is_some_and(|details| {
            details.iter().any(|detail| {
                detail.detail_type.as_deref()
                    == Some("type.googleapis.com/google.firebase.fcm.v1.FcmError")
                    && (detail.error_code.as_deref() == Some("UNREGISTERED")
                        || detail.field_violations.as_ref().is_some_and(|violations| {
                            violations.iter().any(|violation| {
                                violation.field.as_deref() == Some("message.token")
                            })
                        }))
            })
        })
    });
    if invalid_token {
        return DeliveryResult::InvalidEndpoint;
    }
    if status == reqwest::StatusCode::UNAUTHORIZED
        || status == reqwest::StatusCode::FORBIDDEN
        || status == reqwest::StatusCode::NOT_FOUND
        || status == reqwest::StatusCode::TOO_MANY_REQUESTS
        || status.is_server_error()
    {
        return DeliveryResult::Retry;
    }
    DeliveryResult::Failed
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn debug_redacts_service_account_and_cached_token() {
        let client = FcmClient {
            project_id: "private-project".to_string(),
            client_email: "private@example.invalid".to_string(),
            signing_key: EncodingKey::from_secret(b"private-signing-key"),
            access_token: Mutex::new(Some(CachedToken {
                value: "private-access-token".to_string(),
                expires_at: Instant::now(),
            })),
        };

        let debug = format!("{client:?}");
        assert!(debug.contains("[REDACTED]"));
        assert!(!debug.contains("private-project"));
        assert!(!debug.contains("private@example.invalid"));
        assert!(!debug.contains("private-signing-key"));
        assert!(!debug.contains("private-access-token"));
    }

    #[test]
    fn fcm_payload_contains_only_fixed_wake_data_and_destination() {
        assert_eq!(
            fcm_message("token"),
            serde_json::json!({
                "message": {
                    "token": "token",
                    "android": {"priority": "HIGH", "ttl": "3600s"},
                    "data": {"buzz_wake": "1"}
                }
            })
        );
    }

    #[test]
    fn provider_classification_only_disables_explicit_invalid_tokens() {
        let invalid = serde_json::json!({
            "error": {
                "status": "INVALID_ARGUMENT",
                "details": [{
                    "@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError",
                    "errorCode": "UNREGISTERED"
                }]
            }
        });
        assert_eq!(
            classify_response(
                reqwest::StatusCode::BAD_REQUEST,
                invalid.to_string().as_bytes()
            ),
            DeliveryResult::InvalidEndpoint
        );
        assert_eq!(
            classify_response(reqwest::StatusCode::FORBIDDEN, b"{}"),
            DeliveryResult::Retry
        );
        assert_eq!(
            classify_response(reqwest::StatusCode::INTERNAL_SERVER_ERROR, b"{}"),
            DeliveryResult::Retry
        );
        assert_eq!(
            classify_response(reqwest::StatusCode::BAD_REQUEST, b"{}"),
            DeliveryResult::Failed
        );
        let generic_invalid_argument = serde_json::json!({
            "error": {"status": "INVALID_ARGUMENT"}
        });
        assert_eq!(
            classify_response(
                reqwest::StatusCode::BAD_REQUEST,
                generic_invalid_argument.to_string().as_bytes()
            ),
            DeliveryResult::Failed
        );
    }
}
