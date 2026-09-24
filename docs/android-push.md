# Android direct FCM push

The relay has an opt-in private Android profile named `buzz-android-fcm` with
transport `fcm`. It is separate from the public `buzz-ios-dogfood` APNs
profile and does not use the APNs gateway or Apple App Attest.

Enable the profile by setting both `BUZZ_PUSH_ENABLED=true` and
`BUZZ_ANDROID_FCM_SERVICE_ACCOUNT_FILE` to a readable Google service-account
JSON file. The existing APNs gateway setting remains independent; a deployment
may configure either transport or both. NIP-11 advertises only the configured
profiles. If push is enabled, at least one of
`BUZZ_PUSH_GATEWAY_DELIVERY_URL` and
`BUZZ_ANDROID_FCM_SERVICE_ACCOUNT_FILE` is required.

The Android client publishes the raw FCM registration token as the encrypted
NIP-PL lease endpoint. The signed lease still supplies the relay origin,
installation id, generation, subscriptions, expiry, and profile binding. The
relay stores the endpoint hash and effective endpoint material under the
existing push-lease endpoint custody boundary; it never accepts an FCM token
from public tags or an unauthenticated request. Endpoint rotation uses a
higher lease generation. A permanent FCM token error disables only that exact
installation and generation. Revocation and expiry continue to use the normal
NIP-PL tombstone and send-time generation fence.

The relay obtains an OAuth 2.0 access token with a short-lived RS256 JWT signed
by the service-account private key, then calls the Firebase HTTP v1 endpoint:

```text
https://fcm.googleapis.com/v1/projects/<project_id>/messages:send
```

The provider application data is the fixed reconnect signal below. It contains
no event id, channel id, relay URL, lease id, event content, ciphertext, or
provider response:

```json
{"message":{"token":"<destination token>","android":{"priority":"HIGH","ttl":"3600s"},"data":{"buzz_wake":"1"}}}
```

The FCM destination token is transport routing, not application data. Android
must reconnect and fetch authoritative events through its authenticated relay
session, preserving the NIP-PL rule that FCM is only a lossy wake channel.

Production requirements:

- Create/configure the Firebase project and Android application for the exact
  production `applicationId`.
- Enable the Firebase Cloud Messaging API and grant the service account only
  the role needed to send FCM messages.
- Mount the service-account JSON as a protected runtime secret. Never package
  it in the APK, expose it through NIP-11, or log it or OAuth access tokens.
- Keep the relay's HTTPS egress to Google bounded by the configured request
  timeout. Redirects are disabled.
- Treat FCM-specific `UNREGISTERED` or a token-specific `message.token` field
  violation as endpoint invalidation. Generic `INVALID_ARGUMENT`,
  authentication, project configuration, throttling, timeouts, and 5xx
  responses remain retryable or terminal provider failures without revoking a
  lease.

This is a private/self-hosted profile extension of NIP-PL. It is not the public
APNs gateway profile and does not claim public-gateway conformity for FCM until
the FCM profile's constant-body registration and wire tests are published.
