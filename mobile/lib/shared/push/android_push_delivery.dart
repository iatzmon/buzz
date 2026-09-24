import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../community/community.dart';
import '../community/community_storage.dart';
import '../read_state/read_state_format.dart';
import '../read_state/read_state_storage.dart';
import '../relay/nostr_models.dart';
import '../relay/relay_socket.dart';
import 'push_presentation_cache.dart';
import 'push_lease_revocation_outbox.dart';
import 'push_subscription.dart';

const _channel = MethodChannel('buzz/push');
const androidPendingWakeKey = 'buzz.android.push.pending.v1';
const _androidPushPageSize = 64;
const _androidPushMaxFiltersPerReq = 10;
const _androidPushFetchTimeout = Duration(seconds: 6);
const _androidPushContinuationKeyPrefix = 'buzz.android.push.continuation.v1.';
final _channelId = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

/// Composite cursor for one push policy's historical catch-up.
///
/// A null cursor means that policy has not completed its first page yet. The
/// cursor is inclusive of the lower time bound and exclusive of the event ID
/// boundary, so events sharing a timestamp are never skipped.
class AndroidPushFetchContinuation {
  final int policyIndex;
  final int? until;
  final String? beforeId;
  final bool exhausted;

  const AndroidPushFetchContinuation({
    required this.policyIndex,
    required this.until,
    required this.beforeId,
    this.exhausted = false,
  });

  Map<String, dynamic> toJson() => {
    'policyIndex': policyIndex,
    if (until != null) 'until': until,
    if (beforeId != null) 'beforeId': beforeId,
    'exhausted': exhausted,
  };
}

/// Events collected by one Android push wake, with pagination state preserved
/// when the relay or background execution window stops the catch-up early.
class AndroidPushFetchResult {
  final List<NostrEvent> events;
  final bool complete;
  final List<AndroidPushFetchContinuation> continuation;

  AndroidPushFetchResult({
    required Iterable<NostrEvent> events,
    required this.complete,
    Iterable<AndroidPushFetchContinuation> continuation = const [],
  }) : events = List.unmodifiable(events),
       continuation = List.unmodifiable(continuation);

  factory AndroidPushFetchResult.completed(Iterable<NostrEvent> events) =>
      AndroidPushFetchResult(events: events, complete: true);

  factory AndroidPushFetchResult.incomplete(
    Iterable<NostrEvent> events, {
    Iterable<AndroidPushFetchContinuation> continuation = const [],
  }) => AndroidPushFetchResult(
    events: events,
    complete: false,
    continuation: continuation,
  );
}

typedef AndroidPushFetch =
    Future<AndroidPushFetchResult> Function(
      Community community,
      int since,
      List<AndroidPushFetchContinuation> continuation,
    );

/// Matches the persisted NIP-PL policy using only verified public event fields.
bool androidPushFilterMatches(BuzzPushFilter filter, NostrEvent event) {
  bool tags(String name, List<String>? expected) =>
      expected == null ||
      event.tags.any(
        (tag) => tag.length >= 2 && tag[0] == name && expected.contains(tag[1]),
      );
  return filter.kinds.contains(event.kind) &&
      (filter.authors == null || filter.authors!.contains(event.pubkey)) &&
      tags('p', filter.pTags) &&
      tags('h', filter.hTags) &&
      tags('e', filter.eTags);
}

bool _matchesPolicy(
  List<BuzzPushSubscription> subscriptions,
  NostrEvent event,
) => subscriptions.any(
  (subscription) =>
      androidPushFilterMatches(subscription.filter, event) &&
      !subscription.ignore.any(
        (filter) => androidPushFilterMatches(filter, event),
      ) &&
      (subscription.suppress == null ||
          event.tags
                  .where((tag) => tag.length >= 2 && tag[0] == 'p')
                  .map((tag) => tag[1])
                  .toSet()
                  .length <=
              subscription.suppress!.pTagsMax),
);

/// Fails closed for stale permissions, malformed events, read activity and mutes.
bool shouldPresentAndroidPush({
  required Community community,
  required NostrEvent event,
  required int now,
  Map<String, int> readContexts = const {},
}) {
  if (!community.pushNotificationsEnabled ||
      community.pushSubscriptionState.accepted == null ||
      event.pubkey == community.pubkey ||
      event.createdAt < now - 3600 ||
      event.createdAt > now + 60 ||
      !isVerifiedPushPresentationEvent(event)) {
    return false;
  }
  final channels = event.tags
      .where((tag) => tag.length >= 2 && tag[0] == 'h')
      .map((tag) => tag[1])
      .toSet();
  if (channels.length != 1 || !_channelId.hasMatch(channels.single)) {
    return false;
  }
  final readAt = maxReadAt([
    readContexts[channels.single],
    readContexts[msgContextKey(event.id)],
    for (final tag in event.tags)
      if (tag.length >= 4 && tag[0] == 'e' && tag[3] == 'root')
        readContexts[threadContextKey(tag[1])],
  ]);
  if (readAt != null && readAt >= event.createdAt) return false;
  return _matchesPolicy(community.pushSubscriptionState.desired, event) &&
      _matchesPolicy(community.pushSubscriptionState.accepted!, event);
}

/// Fetches through the existing authenticated NIP-42 connection, never FCM data.
///
/// Each REQ contains at most ten policy filters, and every full policy page is
/// continued with the relay's composite `until` + `before_id` cursor. Events
/// are deduplicated by ID across policies and pages. If the six-second wake
/// budget expires after any events have arrived, the events are returned with
/// [AndroidPushFetchResult.complete] false so the caller can present progress
/// while retaining the durable pending wake.
Future<AndroidPushFetchResult> fetchAndroidPushEvents(
  Community community,
  int since, {
  Iterable<AndroidPushFetchContinuation> continuation = const [],
}) async {
  final resumed = {
    for (final cursor in continuation) cursor.policyIndex: cursor,
  };
  final policies = [
    for (
      var index = 0;
      index < community.pushSubscriptionState.desired.length;
      index++
    )
      _AndroidPushPolicyCursor(
        community.pushSubscriptionState.desired[index],
        resumed[index],
      ),
  ];
  final events = <String, NostrEvent>{};
  if (policies.isEmpty) {
    return AndroidPushFetchResult.completed(const []);
  }

  final reader = _AndroidPushRelayReader(community);
  final deadline = DateTime.now().add(_androidPushFetchTimeout);
  var complete = true;
  try {
    await reader.connect().timeout(_remainingUntil(deadline));
    outer:
    for (
      var offset = 0;
      offset < policies.length;
      offset += _androidPushMaxFiltersPerReq
    ) {
      final batch = policies
          .skip(offset)
          .take(_androidPushMaxFiltersPerReq)
          .toList();
      while (batch.any((policy) => !policy.exhausted)) {
        final filters = [
          for (final policy in batch)
            if (!policy.exhausted) _pushCatchUpFilter(policy, since),
        ];
        if (filters.isEmpty) break;
        final page = await reader.request(filters, _remainingUntil(deadline));
        for (final event in page.events) {
          events.putIfAbsent(event.id, () => event);
        }
        if (page.malformed) {
          complete = false;
          break outer;
        }

        for (final policy in batch) {
          if (policy.exhausted) continue;
          final matches =
              page.events
                  .where(
                    (event) =>
                        androidPushFilterMatches(policy.policy.filter, event),
                  )
                  .toList()
                ..sort(_newestPushEventFirst);
          if (matches.length < _androidPushPageSize) {
            policy.exhausted = true;
            continue;
          }
          // A multi-filter REQ returns a deduplicated union. Extra events from
          // another policy can match this policy but lie past its own page;
          // derive the cursor from this policy's first page only.
          final cursor = _oldestPushEvent(
            matches.take(_androidPushPageSize).toList(),
          );
          if (policy.until == cursor.createdAt &&
              policy.beforeId == cursor.id) {
            // A relay that repeats a full page cannot prove exhaustion. Keep
            // the wake pending so a later invocation can retry safely.
            complete = false;
            break outer;
          }
          policy.until = cursor.createdAt;
          policy.beforeId = cursor.id;
        }
      }
    }
  } on TimeoutException {
    for (final event in reader.takePartialEvents()) {
      events.putIfAbsent(event.id, () => event);
    }
    complete = false;
  } on Object {
    for (final event in reader.takePartialEvents()) {
      events.putIfAbsent(event.id, () => event);
    }
    if (events.isEmpty) rethrow;
    complete = false;
  } finally {
    reader.dispose();
  }
  return AndroidPushFetchResult(
    events: events.values,
    complete: complete,
    continuation: [
      for (var index = 0; index < policies.length; index++)
        if (!complete || !policies[index].exhausted)
          AndroidPushFetchContinuation(
            policyIndex: index,
            until: policies[index].until,
            beforeId: policies[index].beforeId,
            exhausted: policies[index].exhausted,
          ),
    ],
  );
}

Map<String, dynamic> _pushCatchUpFilter(
  _AndroidPushPolicyCursor policy,
  int since,
) => {
  ...policy.policy.filter.toJson(),
  'since': since,
  'limit': _androidPushPageSize,
  if (policy.until != null) 'until': policy.until,
  if (policy.beforeId != null) 'before_id': policy.beforeId,
};

Duration _remainingUntil(DateTime deadline) {
  final remaining = deadline.difference(DateTime.now());
  if (remaining <= Duration.zero) {
    throw TimeoutException('Android push catch-up budget expired');
  }
  return remaining;
}

NostrEvent _oldestPushEvent(List<NostrEvent> events) {
  var oldest = events.first;
  for (final event in events.skip(1)) {
    if (event.createdAt < oldest.createdAt ||
        (event.createdAt == oldest.createdAt &&
            event.id.compareTo(oldest.id) > 0)) {
      oldest = event;
    }
  }
  return oldest;
}

int _newestPushEventFirst(NostrEvent a, NostrEvent b) {
  final byTime = b.createdAt.compareTo(a.createdAt);
  return byTime == 0 ? a.id.compareTo(b.id) : byTime;
}

class _AndroidPushPolicyCursor {
  final BuzzPushSubscription policy;
  int? until;
  String? beforeId;
  bool exhausted = false;

  _AndroidPushPolicyCursor(
    this.policy,
    AndroidPushFetchContinuation? continuation,
  ) : until = continuation?.until,
      beforeId = continuation?.beforeId,
      exhausted = continuation?.exhausted ?? false;
}

class _AndroidPushPage {
  final List<NostrEvent> events;
  final bool malformed;

  _AndroidPushPage(Iterable<NostrEvent> events, {required this.malformed})
    : events = List.unmodifiable(events);
}

class _AndroidPushRelayReader {
  late final RelaySocket _socket;
  String? _subscriptionId;
  Completer<_AndroidPushPage>? _page;
  Object? _connectionError;
  var _connected = false;
  var _sequence = 0;

  _AndroidPushRelayReader(Community community) {
    _socket = RelaySocket(
      wsUrl: canonicalBuzzPushRelayOrigin(community.relayUrl),
      nsec: community.nsec,
      onConnected: () => _connected = true,
      onDisconnected: (error) {
        _connected = false;
        _connectionError = error ?? StateError('Push relay disconnected');
        final page = _page;
        if (page != null && !page.isCompleted) {
          page.completeError(_connectionError!);
        }
      },
      onMessage: _handleMessage,
    );
  }

  Future<void> connect() async {
    await _socket.connect();
    if (_connectionError != null) throw _connectionError!;
    if (!_connected) throw StateError('Push relay did not connect');
  }

  Future<_AndroidPushPage> request(
    List<Map<String, dynamic>> filters,
    Duration timeout,
  ) async {
    if (!_connected) throw StateError('Push relay is not connected');
    final subscriptionId = 'android-push-wake-${_sequence++}';
    final page = Completer<_AndroidPushPage>();
    _subscriptionId = subscriptionId;
    _page = page;
    _socket.send(['REQ', subscriptionId, ...filters]);
    try {
      return await page.future.timeout(timeout);
    } finally {
      if (identical(_page, page)) {
        _page = null;
        _subscriptionId = null;
      }
    }
  }

  void _handleMessage(List<dynamic> message) {
    final page = _page;
    if (page == null ||
        page.isCompleted ||
        message.length < 2 ||
        message[1] != _subscriptionId) {
      return;
    }
    if (message[0] == 'EOSE') {
      _socket.send(['CLOSE', _subscriptionId]);
      page.complete(_AndroidPushPage(_events.values, malformed: _malformed));
      _resetPageState();
    } else if (message[0] == 'CLOSED') {
      page.completeError(StateError('Push query refused'));
    } else if (message[0] == 'EVENT' &&
        message.length == 3 &&
        message[2] is Map) {
      try {
        final event = NostrEvent.fromJson(
          Map<String, dynamic>.from(message[2] as Map),
        );
        if (event.content.length <= 65536 && event.tags.length <= 512) {
          _events.putIfAbsent(event.id, () => event);
        } else {
          _malformed = true;
        }
      } on Object {
        _malformed = true;
      }
    }
  }

  final _events = <String, NostrEvent>{};
  var _malformed = false;

  void _resetPageState() {
    _events.clear();
    _malformed = false;
  }

  List<NostrEvent> takePartialEvents() {
    final partial = _events.values.toList(growable: false);
    _resetPageState();
    return partial;
  }

  void dispose() {
    _socket.dispose();
    _page = null;
    _subscriptionId = null;
    _connected = false;
  }
}

String _androidPushContinuationKey(String communityId) =>
    '$_androidPushContinuationKeyPrefix$communityId';

Future<List<AndroidPushFetchContinuation>?> _loadAndroidPushContinuation(
  SharedPreferences prefs, {
  required Community community,
  required int since,
}) async {
  final raw = prefs.getString(_androidPushContinuationKey(community.id));
  if (raw == null) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map ||
        decoded['since'] != since ||
        decoded['fingerprint'] !=
            buzzPushSubscriptionsFingerprint(
              community.pushSubscriptionState.desired,
            ) ||
        decoded['continuation'] is! List) {
      throw const FormatException('Stale Android push continuation.');
    }
    return [
      for (final value in decoded['continuation'] as List)
        _androidPushContinuationFromJson(value),
    ];
  } on Object {
    await prefs.remove(_androidPushContinuationKey(community.id));
    return null;
  }
}

AndroidPushFetchContinuation _androidPushContinuationFromJson(Object? value) {
  if (value is! Map ||
      value['policyIndex'] is! int ||
      value['policyIndex'] < 0 ||
      value['exhausted'] is! bool) {
    throw const FormatException('Malformed Android push continuation.');
  }
  final until = value['until'];
  final beforeId = value['beforeId'];
  if ((until == null) != (beforeId == null) ||
      (until != null && until is! int) ||
      (beforeId != null &&
          (beforeId is! String ||
              !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(beforeId)))) {
    throw const FormatException('Malformed Android push continuation cursor.');
  }
  return AndroidPushFetchContinuation(
    policyIndex: value['policyIndex'] as int,
    until: until as int?,
    beforeId: beforeId as String?,
    exhausted: value['exhausted'] as bool,
  );
}

Future<void> _saveAndroidPushContinuation(
  SharedPreferences prefs, {
  required Community community,
  required int since,
  required AndroidPushFetchResult result,
}) => prefs.setString(
  _androidPushContinuationKey(community.id),
  jsonEncode({
    'since': since,
    'fingerprint': buzzPushSubscriptionsFingerprint(
      community.pushSubscriptionState.desired,
    ),
    'continuation': [for (final cursor in result.continuation) cursor.toJson()],
  }),
);

Future<void> _clearAndroidPushContinuation(
  SharedPreferences prefs,
  String communityId,
) => prefs.remove(_androidPushContinuationKey(communityId));

/// Resolves an opaque wake using local credentials and current per-community policy.
/// Pending work survives a failed fetch and is retried on the next wake or app start.
Future<void> deliverAndroidBuzzWake({
  CommunityStorage? storage,
  AndroidPushFetch? fetch,
  Future<bool> Function(Map<String, String>)? present,
  int Function()? clock,
}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  await prefs.setBool(androidPendingWakeKey, true);
  if (present == null &&
      await _channel.invokeMethod<String>('notificationAuthorizationStatus') !=
          'authorized') {
    await prefs.remove(androidPendingWakeKey);
    return;
  }
  final communities = storage ?? CommunityStorage();
  final now = (clock ?? () => DateTime.now().millisecondsSinceEpoch ~/ 1000)();
  final snapshot = (await communities.loadAll())
      .where(
        (c) =>
            c.pushNotificationsEnabled &&
            c.nsec != null &&
            c.pushSubscriptionState.desired.isNotEmpty,
      )
      .toList();
  // Bound work within FlutterFire's background execution window. Leave a durable
  // pending record when the account count exceeds this batch's time budget.
  final deadline = DateTime.now().add(const Duration(seconds: 24));
  Object? failure;
  for (var offset = 0; offset < snapshot.length; offset += 4) {
    if (DateTime.now().isAfter(deadline.subtract(const Duration(seconds: 6)))) {
      failure = TimeoutException('Push account sync needs another wake');
      break;
    }
    await Future.wait(
      snapshot.skip(offset).take(4).map((community) async {
        try {
          final enabledSince =
              prefs.getInt('buzz.android.push.since.${community.id}') ?? now;
          final since = enabledSince > now - 3600 ? enabledSince : now - 3600;
          final continuation =
              await _loadAndroidPushContinuation(
                prefs,
                community: community,
                since: since,
              ) ??
              const <AndroidPushFetchContinuation>[];
          final result =
              await (fetch ??
                  (c, s, cursors) => fetchAndroidPushEvents(
                    c,
                    s,
                    continuation: cursors,
                  ))(community, since, continuation);
          for (final event in result.events) {
            // Re-read both policy and read state after I/O; opt-out/removal wins.
            final current = (await communities.loadAll())
                .where((c) => c.id == community.id)
                .firstOrNull;
            if (current == null) break;
            if (event.createdAt < since) continue;
            await prefs.reload();
            if (!shouldPresentAndroidPush(
              community: current,
              event: event,
              now: now,
              readContexts: ReadStateStorage(
                prefs,
              ).read(current.pubkey ?? '').contexts,
            )) {
              continue;
            }
            final args = <String, String>{
              'communityId': current.id,
              'channelId': event.tags.firstWhere(
                (tag) => tag.length >= 2 && tag[0] == 'h',
              )[1],
              'eventId': event.id,
            };
            await (present ??
                (args) async =>
                    await _channel.invokeMethod<bool>(
                      'showNotification',
                      args,
                    ) ??
                    false)(args);
          }
          if (!result.complete) {
            await _saveAndroidPushContinuation(
              prefs,
              community: community,
              since: since,
              result: result,
            );
            throw StateError('Android push catch-up remains pending');
          }
          await _clearAndroidPushContinuation(prefs, community.id);
        } on Object catch (error) {
          failure = error;
        }
      }),
    );
  }
  if (failure != null) throw StateError('Android push sync remains pending');
  await prefs.remove(androidPendingWakeKey);
}
