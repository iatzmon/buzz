import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'android_push_delivery.dart';
import 'dev_push_lease.dart';
import 'push_bridge.dart';

/// Opt-in build flag. Android builds require matching external Firebase resources.
const androidPushBuildEnabled = bool.fromEnvironment(
  'BUZZ_ANDROID_FCM_ENABLED',
);
bool get isAndroidPushBuild =>
    !kIsWeb &&
    defaultTargetPlatform == TargetPlatform.android &&
    androidPushBuildEnabled;
final androidPushToken = ValueNotifier<String?>(null);
final androidPushError = ValueNotifier<String?>(null);
const _storage = FlutterSecureStorage();
const _grantsKey = 'buzz.android.push.endpoints.v1';
const _channel = MethodChannel('buzz/push');
Future<void>? _initializing;

/// Installs foreground and terminated-process wake handling without prompting.
Future<void> initializeAndroidPush() async {
  if (!isAndroidPushBuild) return;
  return _initializing ??= _initialize().catchError((Object error) {
    _initializing = null;
    androidPushError.value = 'Android push could not initialize.';
    throw error;
  });
}

Future<void> _initialize() async {
  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(androidBuzzPushBackgroundMessage);
  FirebaseMessaging.onMessage.listen((message) {
    // Foreground activity already has its live event stream; do not duplicate it.
  });
  FirebaseMessaging.instance.onTokenRefresh.listen(
    (token) {
      androidPushToken.value = token;
      androidPushError.value = null;
    },
    onError: (Object _) {
      androidPushError.value = 'Android push registration needs retry.';
    },
  );
}

/// Requests visible notification permission, then obtains the current endpoint.
Future<void> startAndroidPushRegistration() async {
  await initializeAndroidPush();
  await _channel.invokeMethod<void>('startRegistration');
  androidPushToken.value = await FirebaseMessaging.instance.getToken().timeout(
    const Duration(seconds: 8),
  );
  if (androidPushToken.value == null) {
    throw StateError('FCM endpoint unavailable');
  }
  androidPushError.value = null;
}

Future<List<BuzzPushEndpointGrant>> readAndroidPushEndpoints() async {
  final raw = await _storage.read(key: _grantsKey);
  if (raw == null) return const [];
  return (jsonDecode(raw) as List)
      .map((value) => BuzzPushEndpointGrant.fromMap(value as Map))
      .toList();
}

/// Persists endpoint metadata before lease publication so removal can be retried.
Future<BuzzPushEndpointGrant> prepareAndroidPushEndpoint(
  BuzzPushLeaseDescriptor descriptor,
  String token,
) async {
  final all = await readAndroidPushEndpoints();
  final previous = all
      .where((g) => g.relayOrigin == descriptor.origin)
      .firstOrNull;
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  if (previous != null &&
      previous.endpointGrant == token &&
      previous.relayPubkey == descriptor.executorPubkey &&
      previous.expiresAt > now + 600) {
    return previous;
  }
  final grant = BuzzPushEndpointGrant(
    relayOrigin: descriptor.origin,
    relayPubkey: descriptor.executorPubkey,
    installationId:
        previous?.installationId ??
        List.generate(
          16,
          (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join(),
    endpointGrant: token,
    endpointHash:
        '', // Raw token is carried only in the encrypted member lease.
    appProfile: buzzAndroidPushAppProfile,
    endpointEpoch: (previous?.endpointEpoch ?? 0) + 1,
    generation: (previous?.generation ?? 0) + 1,
    expiresAt: now + descriptor.maxLeaseTtlSeconds,
  );
  await _storage.write(
    key: _grantsKey,
    value: jsonEncode([
      for (final item in [
        ...all.where((g) => g.relayOrigin != grant.relayOrigin),
        grant,
      ])
        {
          'relayOrigin': item.relayOrigin,
          'relayPubkey': item.relayPubkey,
          'installationId': item.installationId,
          'endpointGrant': item.endpointGrant,
          'endpointHash': item.endpointHash,
          'appProfile': item.appProfile,
          'endpointEpoch': item.endpointEpoch,
          'generation': item.generation,
          'expiresAt': item.expiresAt,
        },
    ]),
  );
  return grant;
}

/// Entry point invoked by FlutterFire in its registered background engine.
@pragma('vm:entry-point')
Future<void> androidBuzzPushBackgroundMessage(RemoteMessage message) async {
  if (message.data.length != 1 ||
      message.data['buzz_wake'] != '1' ||
      message.notification != null) {
    return;
  }
  await Firebase.initializeApp();
  await deliverAndroidBuzzWake();
}
