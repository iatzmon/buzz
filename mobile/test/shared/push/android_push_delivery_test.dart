import 'dart:convert';
import 'dart:io';

import 'package:buzz/shared/community/community.dart';
import 'package:buzz/shared/community/community_storage.dart';
import 'package:buzz/shared/push/android_push_delivery.dart';
import 'package:buzz/shared/push/push_lease_revocation_outbox.dart';
import 'package:buzz/shared/push/push_subscription.dart';
import 'package:buzz/shared/relay/nostr_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nostr/nostr.dart' as nostr;
import 'package:shared_preferences/shared_preferences.dart';

const channel = '123e4567-e89b-42d3-a456-426614174000';
const now = 1790000000;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final member = nostr.Keys.generate();
  final sender = nostr.Keys.generate();
  final subscriptions = buildDesiredBuzzPushSubscriptions(
    myPubkey: member.public,
    channelIds: [channel],
  );
  final community =
      Community.create(
        name: 'Test',
        relayUrl: 'wss://relay.example',
        pubkey: member.public,
        nsec: member.nsec,
      ).copyWith(
        pushNotificationsEnabled: true,
        pushSubscriptionState: BuzzPushLeaseSubscriptionState.accepted(
          desired: subscriptions,
          acceptedSubscriptions: subscriptions,
          acceptedGeneration: 1,
        ),
      );
  NostrEvent event({
    int timestamp = now,
    String? author,
    List<List<String>>? tags,
  }) => NostrEvent.fromJson(
    nostr.Event.from(
      kind: 9,
      content: 'Private test text',
      tags:
          tags ??
          [
            ['h', channel],
          ],
      secretKey: author ?? sender.secret,
      createdAt: timestamp,
    ).toMap(),
  );

  setUp(
    () => SharedPreferences.setMockInitialValues({
      'buzz.android.push.since.${community.id}': now - 60,
    }),
  );

  test('Android preview strips markup and bounds message text', () {
    expect(
      androidPushPreviewBody(
        ' Hello  **team**\n![image](https://example.com/photo) '
        'https://example.com/private `code` ```secret\nblock```',
      ),
      'Hello **team** image [link] code [code]',
    );
    expect(androidPushPreviewBody('  \n  '), isEmpty);
    final longPreview = androidPushPreviewBody('😀' * 200);
    expect(longPreview.runes.length, 178);
    expect(longPreview.endsWith('…'), isTrue);
  });

  test('pairs HTTPS relay URLs with HTTPS REST and WSS sockets', () {
    expect(
      canonicalBuzzPushRelayHttpUrl('https://relay.example'),
      'https://relay.example/',
    );
    expect(
      canonicalBuzzPushRelayOrigin('https://relay.example'),
      'wss://relay.example',
    );
    expect(
      canonicalBuzzPushRelayHttpUrl('http://relay.example'),
      'http://relay.example/',
    );
    expect(
      canonicalBuzzPushRelayOrigin('http://relay.example'),
      'ws://relay.example',
    );
    expect(
      canonicalBuzzPushRelayHttpUrl('wss://relay.example'),
      'https://relay.example/',
    );
    expect(
      canonicalBuzzPushRelayOrigin('wss://relay.example'),
      'wss://relay.example',
    );
    expect(
      canonicalBuzzPushRelayHttpUrl('ws://relay.example'),
      'http://relay.example/',
    );
    expect(
      canonicalBuzzPushRelayOrigin('ws://relay.example'),
      'ws://relay.example',
    );
  });

  test(
    'signed, unread matching message is presented; every fence rejects independently',
    () {
      final valid = event();
      bool admit({
        Community? c,
        NostrEvent? e,
        Map<String, int> reads = const {},
      }) => shouldPresentAndroidPush(
        community: c ?? community,
        event: e ?? valid,
        now: now,
        readContexts: reads,
      );
      expect(admit(), isTrue);
      expect(
        admit(c: community.copyWith(pushNotificationsEnabled: false)),
        isFalse,
      );
      expect(
        admit(
          c: community.copyWith(
            pushSubscriptionState: BuzzPushLeaseSubscriptionState.desired(
              desired: subscriptions,
            ),
          ),
        ),
        isFalse,
      );
      expect(admit(e: event(author: member.secret)), isFalse);
      expect(admit(e: event(timestamp: now - 3601)), isFalse);
      expect(admit(e: event(timestamp: now + 61)), isFalse);
      expect(admit(e: event(tags: [])), isFalse);
      expect(
        admit(
          e: event(
            tags: [
              ['h', channel],
              ['h', 'different-channel'],
            ],
          ),
        ),
        isFalse,
      );
      expect(admit(reads: {channel: now}), isFalse);
      expect(
        admit(
          e: NostrEvent.fromJson({...valid.toJson(), 'content': 'tampered'}),
        ),
        isFalse,
      );
      final muted = buildDesiredBuzzPushSubscriptions(
        myPubkey: member.public,
        channelIds: [channel],
        mutedChannelIds: [channel],
      );
      expect(
        admit(
          c: community.copyWith(
            pushSubscriptionState: community.pushSubscriptionState.withDesired(
              muted,
            ),
          ),
        ),
        isFalse,
      );
    },
  );

  test('overlapping policy pages honor each policy cursor window', () async {
    final overlapChannel = '22345678-1234-4abc-8def-123456789012';
    final channelPolicy = BuzzPushSubscription(
      filter: BuzzPushFilter(kinds: [9], hTags: [overlapChannel]),
      notificationClass: 'default',
    );
    final authorPolicy = BuzzPushSubscription(
      filter: BuzzPushFilter(kinds: [9], authors: [sender.public]),
      notificationClass: 'default',
    );
    final overlappingCommunity = community.copyWith(
      relayUrl: 'ws://127.0.0.1',
      pushSubscriptionState: BuzzPushLeaseSubscriptionState.accepted(
        desired: [channelPolicy, authorPolicy],
        acceptedSubscriptions: [channelPolicy, authorPolicy],
        acceptedGeneration: 1,
      ),
    );
    final older = NostrEvent.fromJson(
      nostr.Event.from(
        kind: 9,
        content: 'older channel event',
        tags: [
          ['h', overlapChannel],
        ],
        secretKey: sender.secret,
        createdAt: now - 10,
      ).toMap(),
    );
    final newer = [
      for (var index = 0; index < 64; index++)
        NostrEvent.fromJson(
          nostr.Event.from(
            kind: 9,
            content: 'newer overlapping event $index',
            tags: [
              ['h', overlapChannel],
            ],
            secretKey: sender.secret,
            createdAt: now + 10,
          ).toMap(),
        ),
    ];
    final allEvents = [older, ...newer];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <WebSocket>[];
    var queryCount = 0;
    addTearDown(() async {
      for (final socket in sockets) {
        await socket.close();
      }
      await server.close(force: true);
    });
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.add(jsonEncode(['AUTH', 'overlap-challenge']));
      socket.listen((raw) {
        final frame = jsonDecode(raw as String) as List<dynamic>;
        if (frame[0] == 'AUTH') {
          final auth = nostr.Event.fromJson(jsonEncode(frame[1]));
          socket.add(jsonEncode(['OK', auth.id, true, '']));
          return;
        }
        if (frame[0] != 'REQ') return;
        queryCount++;
        final seen = <String>{};
        for (final rawFilter in frame.skip(2)) {
          final filter = Map<String, dynamic>.from(rawFilter as Map);
          final kinds = (filter['kinds'] as List).cast<int>();
          final authors = (filter['authors'] as List?)?.cast<String>();
          final channels = (filter['#h'] as List?)?.cast<String>();
          final since = filter['since'] as int;
          final until = filter['until'] as int?;
          final beforeId = filter['before_id'] as String?;
          final candidates =
              allEvents
                  .where(
                    (event) =>
                        kinds.contains(event.kind) &&
                        (authors == null || authors.contains(event.pubkey)) &&
                        (channels == null ||
                            event.tags.any(
                              (tag) =>
                                  tag.length >= 2 &&
                                  tag[0] == 'h' &&
                                  channels.contains(tag[1]),
                            )) &&
                        event.createdAt >= since &&
                        (until == null ||
                            event.createdAt < until ||
                            (event.createdAt == until &&
                                (beforeId == null ||
                                    event.id.compareTo(beforeId) > 0))),
                  )
                  .toList()
                ..sort((a, b) {
                  final byTime = b.createdAt.compareTo(a.createdAt);
                  return byTime == 0 ? a.id.compareTo(b.id) : byTime;
                });
          for (final event in candidates.take(filter['limit'] as int)) {
            if (seen.add(event.id)) {
              socket.add(jsonEncode(['EVENT', frame[1], event.toJson()]));
            }
          }
        }
        socket.add(jsonEncode(['EOSE', frame[1]]));
      });
    });

    final result = await fetchAndroidPushEvents(
      overlappingCommunity.copyWith(relayUrl: 'ws://127.0.0.1:${server.port}'),
      now - 60,
      continuation: [
        AndroidPushFetchContinuation(
          policyIndex: 0,
          until: now,
          beforeId: 'f' * 64,
        ),
        const AndroidPushFetchContinuation(
          policyIndex: 1,
          until: null,
          beforeId: null,
        ),
      ],
    );
    expect(result.complete, isTrue);
    expect(result.events.map((event) => event.id).toSet(), hasLength(65));
    expect(queryCount, 2);
  });

  test(
    'production fetch authenticates then reads a bounded subscription',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      addTearDown(() async {
        for (final socket in sockets) {
          await socket.close();
        }
        await server.close(force: true);
      });
      final valid = event();
      var authenticated = false;
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.add(jsonEncode(['AUTH', 'test-challenge']));
        socket.listen((raw) {
          final frame = jsonDecode(raw as String) as List;
          if (frame[0] == 'AUTH') {
            final auth = nostr.Event.fromJson(jsonEncode(frame[1]));
            expect(auth.kind, 22242);
            expect(auth.pubkey, member.public);
            expect(
              auth.tags.any(
                (tag) =>
                    tag.length == 2 &&
                    tag[0] == 'challenge' &&
                    tag[1] == 'test-challenge',
              ),
              isTrue,
            );
            authenticated = true;
            socket.add(jsonEncode(['OK', auth.id, true, '']));
          } else if (frame[0] == 'REQ') {
            expect(authenticated, isTrue);
            expect((frame[2] as Map)['since'], now - 10);
            expect((frame[2] as Map)['limit'], 64);
            socket.add(jsonEncode(['EVENT', frame[1], valid.toJson()]));
            socket.add(jsonEncode(['EOSE', frame[1]]));
          }
        });
      });
      final found = await fetchAndroidPushEvents(
        community.copyWith(relayUrl: 'ws://127.0.0.1:${server.port}'),
        now - 10,
      );
      expect(found.complete, isTrue);
      expect(found.events.map((e) => e.id), [valid.id]);
      expect(authenticated, isTrue);
    },
  );

  test(
    'catch-up batches eleven policies and pages more than 128 same-second events',
    () async {
      final channels = [
        for (var index = 0; index < 11; index++)
          '12345678-1234-4abc-8def-${(index + 1).toString().padLeft(12, '0')}',
      ];
      final policies = [
        for (final channelId in channels)
          BuzzPushSubscription(
            filter: BuzzPushFilter(kinds: [9], hTags: [channelId]),
            notificationClass: 'default',
          ),
      ];
      final pagedCommunity =
          Community.create(
            name: 'Paged test',
            relayUrl: 'ws://127.0.0.1',
            pubkey: member.public,
            nsec: member.nsec,
          ).copyWith(
            pushNotificationsEnabled: true,
            pushSubscriptionState: BuzzPushLeaseSubscriptionState.accepted(
              desired: policies,
              acceptedSubscriptions: policies,
              acceptedGeneration: 1,
            ),
          );
      final allEvents = [
        for (
          var channelIndex = 0;
          channelIndex < channels.length;
          channelIndex++
        )
          for (
            var eventIndex = 0;
            eventIndex < (channelIndex < 2 ? 70 : 1);
            eventIndex++
          )
            NostrEvent.fromJson(
              nostr.Event.from(
                kind: 9,
                content: 'same-second-$channelIndex-$eventIndex',
                tags: [
                  ['h', channels[channelIndex]],
                ],
                secretKey: sender.secret,
                createdAt: now,
              ).toMap(),
            ),
      ];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      var queryCount = 0;
      var maxFilters = 0;
      var pagedRequestSeen = false;
      addTearDown(() async {
        for (final socket in sockets) {
          await socket.close();
        }
        await server.close(force: true);
      });
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.add(jsonEncode(['AUTH', 'paged-challenge']));
        socket.listen((raw) {
          final frame = jsonDecode(raw as String) as List<dynamic>;
          if (frame[0] == 'AUTH') {
            final auth = nostr.Event.fromJson(jsonEncode(frame[1]));
            socket.add(jsonEncode(['OK', auth.id, true, '']));
            return;
          }
          if (frame[0] != 'REQ') return;
          queryCount++;
          final filters = [
            for (final rawFilter in frame.skip(2))
              Map<String, dynamic>.from(rawFilter as Map),
          ];
          maxFilters = maxFilters < filters.length
              ? filters.length
              : maxFilters;
          final seen = <String>{};
          final page = <NostrEvent>[];
          for (final filter in filters) {
            final channelId = (filter['#h'] as List).single as String;
            final since = filter['since'] as int;
            final until = filter['until'] as int?;
            final beforeId = filter['before_id'] as String?;
            final candidates =
                allEvents
                    .where(
                      (event) =>
                          event.tags.any(
                            (tag) =>
                                tag.length >= 2 &&
                                tag[0] == 'h' &&
                                tag[1] == channelId,
                          ) &&
                          event.createdAt >= since &&
                          (until == null ||
                              event.createdAt < until ||
                              (event.createdAt == until &&
                                  (beforeId == null ||
                                      event.id.compareTo(beforeId) > 0))),
                    )
                    .toList()
                  ..sort((a, b) {
                    final byTime = b.createdAt.compareTo(a.createdAt);
                    return byTime == 0 ? a.id.compareTo(b.id) : byTime;
                  });
            final limit = filter['limit'] as int;
            if (beforeId != null) pagedRequestSeen = true;
            for (final event in candidates.take(limit)) {
              if (seen.add(event.id)) page.add(event);
            }
          }
          for (final event in page) {
            socket.add(jsonEncode(['EVENT', frame[1], event.toJson()]));
          }
          socket.add(jsonEncode(['EOSE', frame[1]]));
        });
      });

      final result = await fetchAndroidPushEvents(
        pagedCommunity.copyWith(relayUrl: 'ws://127.0.0.1:${server.port}'),
        now - 10,
      );
      expect(result.complete, isTrue);
      expect(result.continuation, isEmpty);
      expect(result.events.map((event) => event.id).toSet(), hasLength(149));
      expect(maxFilters, 10);
      expect(queryCount, 3);
      expect(pagedRequestSeen, isTrue);
    },
  );

  test(
    'relay CLOSED after partial page returns received events for retry',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      final valid = event();
      addTearDown(() async {
        for (final socket in sockets) {
          await socket.close();
        }
        await server.close(force: true);
      });
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.add(jsonEncode(['AUTH', 'closed-challenge']));
        socket.listen((raw) {
          final frame = jsonDecode(raw as String) as List<dynamic>;
          if (frame[0] == 'AUTH') {
            final auth = nostr.Event.fromJson(jsonEncode(frame[1]));
            socket.add(jsonEncode(['OK', auth.id, true, '']));
          } else if (frame[0] == 'REQ') {
            socket.add(jsonEncode(['EVENT', frame[1], valid.toJson()]));
            socket.add(jsonEncode(['CLOSED', frame[1], 'temporary']));
          }
        });
      });
      final result = await fetchAndroidPushEvents(
        community.copyWith(relayUrl: 'ws://127.0.0.1:${server.port}'),
        now - 10,
      );
      expect(result.complete, isFalse);
      expect(result.events.map((e) => e.id), [valid.id]);
      expect(result.continuation, hasLength(2));
    },
  );

  test(
    'opt-out during fetch wins and removes the durable pending wake',
    () async {
      final storage = _MemoryCommunities([community]);
      final shown = <Map<String, String>>[];
      await deliverAndroidBuzzWake(
        storage: storage,
        clock: () => now,
        fetch: (c, since, _) async {
          storage.communities = [
            community.copyWith(pushNotificationsEnabled: false),
          ];
          return AndroidPushFetchResult.completed([event()]);
        },
        present: (args) async {
          shown.add(args);
          return true;
        },
      );
      expect(shown, isEmpty);
      expect(
        (await SharedPreferences.getInstance()).getBool(androidPendingWakeKey),
        isNull,
      );
    },
  );

  test(
    'failed fetch leaves durable retry; verified delivery includes preview',
    () async {
      final storage = _MemoryCommunities([community]);
      await expectLater(
        deliverAndroidBuzzWake(
          storage: storage,
          clock: () => now,
          fetch: (_, _, _) async => throw StateError('offline'),
          present: (_) async => true,
        ),
        throwsStateError,
      );
      expect(
        (await SharedPreferences.getInstance()).getBool(androidPendingWakeKey),
        isTrue,
      );
      final shown = <Map<String, String>>[];
      final valid = event();
      await deliverAndroidBuzzWake(
        storage: storage,
        clock: () => now,
        fetch: (_, _, _) async => AndroidPushFetchResult.completed([valid]),
        present: (args) async {
          shown.add(args);
          return true;
        },
      );
      expect(shown, [
        {
          'communityId': community.id,
          'channelId': channel,
          'eventId': valid.id,
          'preview': 'Private test text',
        },
      ]);
      expect(
        (await SharedPreferences.getInstance()).getBool(androidPendingWakeKey),
        isNull,
      );
    },
  );

  test(
    'partial catch-up presents progress and keeps the durable wake',
    () async {
      final storage = _MemoryCommunities([community]);
      final valid = event();
      final shown = <Map<String, String>>[];
      List<AndroidPushFetchContinuation>? resumed;
      int? resumedSince;
      await expectLater(
        deliverAndroidBuzzWake(
          storage: storage,
          clock: () => now,
          fetch: (_, _, _) async => AndroidPushFetchResult.incomplete(
            [valid],
            continuation: [
              AndroidPushFetchContinuation(
                policyIndex: 0,
                until: now,
                beforeId: 'a' * 64,
                exhausted: false,
              ),
              AndroidPushFetchContinuation(
                policyIndex: 1,
                until: null,
                beforeId: null,
                exhausted: true,
              ),
            ],
          ),
          present: (args) async {
            shown.add(args);
            return true;
          },
        ),
        throwsStateError,
      );
      expect(shown, [
        {
          'communityId': community.id,
          'channelId': channel,
          'eventId': valid.id,
          'preview': 'Private test text',
        },
      ]);
      expect(
        (await SharedPreferences.getInstance()).getBool(androidPendingWakeKey),
        isTrue,
      );

      await deliverAndroidBuzzWake(
        storage: storage,
        clock: () => now + 7200,
        fetch: (_, since, continuation) async {
          resumedSince = since;
          resumed = continuation;
          return AndroidPushFetchResult.completed(const []);
        },
        present: (_) async => true,
      );
      expect(resumedSince, now - 60);
      expect(resumed, hasLength(2));
      expect(resumed!.first.until, now);
      expect(resumed!.first.beforeId, 'a' * 64);
      expect(resumed!.last.exhausted, isTrue);
      expect(
        (await SharedPreferences.getInstance()).getBool(androidPendingWakeKey),
        isNull,
      );
    },
  );
}

class _MemoryCommunities extends CommunityStorage {
  _MemoryCommunities(this.communities);
  List<Community> communities;
  @override
  Future<List<Community>> loadAll() async => communities;
}
