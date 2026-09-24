import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nostr/nostr.dart' as nostr;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:buzz/main.dart' as app;
import 'package:buzz/shared/community/community.dart';
import 'package:buzz/shared/community/community_storage.dart';
import 'package:buzz/shared/push/android_push_delivery.dart';
import 'package:buzz/shared/push/push_bridge.dart';
import 'package:buzz/shared/push/push_snapshot.dart';
import 'package:buzz/shared/push/push_subscription.dart';
import 'package:buzz/shared/relay/nostr_models.dart';

const _pushChannel = MethodChannel('buzz/push');
const _channelId = '12345678-1234-4abc-8def-1234567890ab';

Future<void> main() async {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('authenticated local Android push delivery and tap', (
    tester,
  ) async {
    // Start the real application embedding so the production plugin, method
    // handler, and MainActivity notification intent path are installed.
    app.main();
    await tester.pump(const Duration(seconds: 2));
    pendingPushNotificationLink.value = null;

    final fixture = await _LocalNip42Fixture.start();
    addTearDown(fixture.close);

    final community = fixture.community;
    final subscription = fixture.subscription;
    final storage = CommunityStorage();
    await storage.saveAll([community]);

    final prefs = await SharedPreferences.getInstance();
    final sinceKey = 'buzz.android.push.since.${community.id}';
    await prefs.setInt(
      sinceKey,
      DateTime.now().millisecondsSinceEpoch ~/ 1000 - 3600,
    );

    // This is the same native snapshot and restoration boundary used by the
    // production bridge. The direct channel call keeps this test independent
    // of the optional FCM build flag and never installs a test receiver.
    await _pushChannel.invokeMethod<void>('syncPushSnapshot', {
      'section': 'communities',
      'communities': [
        BuzzPushCommunitySnapshot(
          id: community.id,
          name: community.name,
          relayUrl: community.relayUrl,
          pubkey: community.pubkey,
          subscriptions: [subscription],
        ).toJson(),
      ],
    });
    await _pushChannel.invokeMethod<void>('restoreAgeRestrictedNotifications');

    final initialAuthorization = await _readAuthorization();
    var deniedBeforeGrant = false;
    if (initialAuthorization == 'notDetermined') {
      debugPrint('ANDROID_PUSH_PERMISSION_DIALOG');
      await _pushChannel.invokeMethod<void>('startRegistration');
      final denied = await _waitForAuthorization(
        tester,
        'denied',
        timeout: const Duration(seconds: 20),
      );
      expect(denied, 'denied');
      deniedBeforeGrant = true;

      // Exercise the production authorization gate while Android is denied:
      // it clears the durable wake and does not query the local relay.
      await deliverAndroidBuzzWake(storage: storage);
      expect(fixture.queryCount, 0);
      await prefs.reload();
      expect(prefs.getBool(androidPendingWakeKey), isNull);
      debugPrint('ANDROID_PUSH_PERMISSION_DENIED');
    }
    final authorization = await _waitForAuthorization(
      tester,
      'authorized',
      timeout: const Duration(seconds: 20),
    );
    expect(
      authorization,
      'authorized',
      reason: 'The host driver must grant POST_NOTIFICATIONS after denial.',
    );

    await binding.convertFlutterSurfaceToImage();
    await tester.pump();
    await binding.takeScreenshot('android-push-ready');

    // The host driver watches this marker, sends HOME, and then taps the real
    // notification from the system shade while this production call blocks.
    debugPrint('ANDROID_PUSH_BACKGROUND_READY community=${community.id}');
    await deliverAndroidBuzzWake(storage: storage);

    expect(fixture.authenticated, isTrue);
    expect(fixture.authenticationError, isNull);
    expect(fixture.queryCount, 1);

    final warmLink = await _waitForNotificationLink(
      tester,
      timeout: const Duration(seconds: 25),
    );
    expect(warmLink.communityId, community.id);
    expect(warmLink.channelId, _channelId);
    expect(warmLink.messageId, fixture.firstEvent.id);
    // Give the host driver time to persist post-tap activity/logcat evidence
    // before integrationDriver terminates the test process.
    await tester.pump(const Duration(seconds: 3));

    expect(fixture.queryCount, 1);
    expect(fixture.authenticationError, isNull);

    await prefs.reload();
    expect(prefs.getBool(androidPendingWakeKey), isNull);
    expect(await _readAuthorization(), 'authorized');

    binding.reportData = {
      ...?binding.reportData,
      'transport': 'authenticated local NIP-42 WebSocket fixture',
      'firebaseFcm': 'not exercised; credentials are unavailable',
      'permissionInitially': initialAuthorization,
      'permissionDeniedBeforeGrant': deniedBeforeGrant,
      'permissionGrantedForDelivery': authorization,
      'communityId': community.id,
      'channelId': _channelId,
      'eventId': fixture.firstEvent.id,
      'authEventVerified': fixture.authenticated,
      'relayQueries': fixture.queryCount,
      'warmTap': {
        'communityId': warmLink.communityId,
        'channelId': warmLink.channelId,
        'eventId': warmLink.messageId,
      },
    };
    await binding.takeScreenshot('android-push-denied');

    await _pushChannel.invokeMethod<void>('syncPushSnapshot', {
      'section': 'communities',
      'communities': const <Map<String, dynamic>>[],
    });
    await storage.saveAll(const []);
  });
}

Future<String> _readAuthorization() async =>
    await _pushChannel.invokeMethod<String>(
      'notificationAuthorizationStatus',
    ) ??
    'unknown';

Future<String> _waitForAuthorization(
  WidgetTester tester,
  String expected, {
  required Duration timeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  var current = await _readAuthorization();
  while (current != expected && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 250));
    current = await _readAuthorization();
  }
  return current;
}

Future<dynamic> _waitForNotificationLink(
  WidgetTester tester, {
  required Duration timeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (pendingPushNotificationLink.value == null &&
      DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 250));
  }
  final link = pendingPushNotificationLink.value;
  if (link == null) {
    fail('The real Android notification tap did not reach Dart.');
  }
  return link;
}

class _LocalNip42Fixture {
  _LocalNip42Fixture._({
    required this.server,
    required this.community,
    required this.subscription,
    required this.firstEvent,
    required this.secondEvent,
  });

  final HttpServer server;
  final Community community;
  final BuzzPushSubscription subscription;
  final nostr.Event firstEvent;
  final nostr.Event secondEvent;
  WebSocket? _socket;
  bool authenticated = false;
  Object? authenticationError;
  int queryCount = 0;

  static Future<_LocalNip42Fixture> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final communityKeys = nostr.Keys.generate();
    final eventKeys = nostr.Keys.generate();
    final relayUrl = 'ws://127.0.0.1:${server.port}';
    final filter = BuzzPushFilter(
      kinds: const [EventKind.streamMessage],
      authors: [eventKeys.public],
      pTags: [communityKeys.public],
      hTags: const [_channelId],
    );
    final subscription = BuzzPushSubscription(
      filter: filter,
      notificationClass: 'default',
    );
    final community =
        Community.create(
          name: 'Android push fixture',
          relayUrl: relayUrl,
          pubkey: communityKeys.public,
          nsec: communityKeys.nsec,
        ).copyWith(
          pushNotificationsEnabled: true,
          pushSubscriptionState: BuzzPushLeaseSubscriptionState.accepted(
            desired: [subscription],
            acceptedSubscriptions: [subscription],
            acceptedGeneration: 1,
            generationCursor: 1,
          ),
        );
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final firstEvent = nostr.Event.from(
      kind: EventKind.streamMessage,
      content: 'local authenticated push fixture: first event',
      secretKey: eventKeys.secret,
      createdAt: now,
      tags: [
        ['h', _channelId],
        ['p', communityKeys.public],
      ],
    );
    final secondEvent = nostr.Event.from(
      kind: EventKind.streamMessage,
      content: 'local authenticated push fixture: denied event',
      secretKey: eventKeys.secret,
      createdAt: now,
      tags: [
        ['h', _channelId],
        ['p', communityKeys.public],
      ],
    );
    final fixture = _LocalNip42Fixture._(
      server: server,
      community: community,
      subscription: subscription,
      firstEvent: firstEvent,
      secondEvent: secondEvent,
    );
    server.listen(fixture._accept);
    return fixture;
  }

  void _accept(HttpRequest request) {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..close();
      return;
    }
    unawaited(_upgrade(request));
  }

  Future<void> _upgrade(HttpRequest request) async {
    try {
      final socket = await WebSocketTransformer.upgrade(request);
      _socket = socket;
      socket.add(jsonEncode(const ['AUTH', 'buzz-local-nip42-challenge']));
      socket.listen(
        (raw) => unawaited(_handleFrame(socket, raw)),
        onError: (Object error) => authenticationError ??= error,
      );
    } catch (error) {
      authenticationError ??= error;
    }
  }

  Future<void> _handleFrame(WebSocket socket, Object? raw) async {
    try {
      final frame = jsonDecode(raw as String) as List<dynamic>;
      if (frame.isEmpty) return;
      switch (frame[0]) {
        case 'AUTH':
          final auth = nostr.Event.fromMap(
            Map<String, dynamic>.from(frame[1] as Map),
          );
          final hasChallenge = auth.tags.any(
            (tag) =>
                tag.length >= 2 &&
                tag[0] == 'challenge' &&
                tag[1] == 'buzz-local-nip42-challenge',
          );
          final hasRelay = auth.tags.any(
            (tag) =>
                tag.length >= 2 &&
                tag[0] == 'relay' &&
                tag[1] == community.relayUrl,
          );
          if (auth.kind != EventKind.auth || !hasChallenge || !hasRelay) {
            throw StateError('Fixture received an invalid NIP-42 AUTH event.');
          }
          authenticated = true;
          socket.add(
            jsonEncode(['OK', auth.id, true, 'authenticated by local fixture']),
          );
        case 'REQ':
          if (frame.length < 3 || frame[1] != 'android-push-wake') {
            throw StateError('Fixture received an unexpected REQ frame.');
          }
          queryCount++;
          final event = queryCount == 1 ? firstEvent : secondEvent;
          socket.add(jsonEncode(['EVENT', 'android-push-wake', event.toMap()]));
          socket.add(jsonEncode(const ['EOSE', 'android-push-wake']));
      }
    } catch (error) {
      authenticationError ??= error;
    }
  }

  Future<void> close() async {
    await _socket?.close();
    await server.close(force: true);
  }
}
