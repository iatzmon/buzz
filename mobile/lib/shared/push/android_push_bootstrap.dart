import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../community/community_provider.dart';
import '../relay/signed_event_relay.dart';
import '../relay/relay_provider.dart';
import 'android_push_delivery.dart';
import 'android_push_registration.dart';
import 'dev_push_lease.dart';
import 'push_bridge.dart';
import 'push_lease_revocation_outbox.dart';
import 'push_subscription.dart';

/// A cached publication remains reusable only while its durable generation wins.
bool androidPushLeaseGenerationIsCurrent(
  BuzzPushLeaseSubscriptionState state,
  int generation,
) =>
    state.accepted != null &&
    state.acceptedGeneration == generation &&
    state.generationCursor == generation &&
    state.pendingTombstoneGeneration == null;

/// Renews every opted-in Android community, including inactive communities.
class AndroidBuzzPushBootstrap extends HookConsumerWidget {
  const AndroidBuzzPushBootstrap({required this.child, super.key});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    useListenable(androidPushToken);
    final communities = ref.watch(communityListProvider).value ?? const [];
    final cleanup = ref.watch(buzzPushLeaseRevocationOutboxProvider);
    final tick = useState(0);
    final tail = useRef<Future<void>>(Future.value());
    final accepted = useRef(
      <String, ({String fingerprint, int renewAt, int generation})>{},
    );
    accepted.value.removeWhere(
      (id, _) =>
          !communities.any((c) => c.id == id && c.pushNotificationsEnabled),
    );
    useEffect(() {
      final timer = Timer.periodic(
        const Duration(minutes: 1),
        (_) => tick.value++,
      );
      final lifecycle = AppLifecycleListener(onResume: () => tick.value++);
      unawaited(
        cleanup.start().catchError((Object _) {
          androidPushError.value =
              'Notification cleanup is waiting for connectivity.';
        }),
      );
      return () {
        timer.cancel();
        lifecycle.dispose();
      };
    }, [cleanup]);
    final fingerprint = communities
        .map(
          (c) =>
              '${c.id}|${c.relayUrl}|${c.pubkey}|'
              '${c.pushNotificationsEnabled}|${buzzPushSubscriptionsFingerprint(c.pushSubscriptionState.desired)}',
        )
        .join(';');
    useEffect(() {
      var cancelled = false;
      final operation = tail.value.then((_) async {
        if (cancelled) return;
        try {
          await cleanup.trigger();
        } on Object {
          androidPushError.value =
              'Notification cleanup is waiting for connectivity.';
        }
        var failed = false;
        for (final community in communities) {
          try {
            if (cancelled) return;
            if (!community.pushNotificationsEnabled &&
                community.pushSubscriptionState.pendingTombstoneGeneration !=
                    null) {
              await ref
                  .read(communityListProvider.notifier)
                  .retryPendingPushLeaseTombstone(
                    community.id,
                    advanceGeneration: true,
                  );
              continue;
            }
            final memberPubkey =
                community.pubkey ?? pubkeyFromNsec(community.nsec);
            if (!community.pushNotificationsEnabled ||
                community.nsec == null ||
                memberPubkey == null ||
                community.pushSubscriptionState.desired.isEmpty) {
              continue;
            }
            final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
            final key =
                '${androidPushToken.value}|${community.relayUrl}|${community.pubkey}|'
                '${buzzPushSubscriptionsFingerprint(community.pushSubscriptionState.desired)}';
            final previous = accepted.value[community.id];
            if (previous?.fingerprint == key &&
                previous!.renewAt > now &&
                androidPushLeaseGenerationIsCurrent(
                  community.pushSubscriptionState,
                  previous.generation,
                )) {
              continue;
            }
            final descriptor = await fetchBuzzPushLeaseDescriptor(
              canonicalBuzzPushRelayHttpUrl(community.relayUrl),
              appProfile: buzzAndroidPushAppProfile,
              expectedTransport: buzzAndroidPushTransport,
            );
            if (cancelled) return;
            await startAndroidPushRegistration();
            if (cancelled) return;
            final token = androidPushToken.value;
            if (token == null) {
              throw StateError('Android push endpoint unavailable');
            }
            final endpoint = await prepareAndroidPushEndpoint(
              descriptor,
              token,
            );
            if (cancelled) return;
            final notifier = ref.read(communityListProvider.notifier);
            final generation = await notifier.reservePushLeaseGeneration(
              community.id,
            );
            if (cancelled) return;
            await publishBuzzDevPushLease(
              grant: endpoint,
              descriptor: descriptor,
              leaseInstallationId: community.pushLeaseInstallationId,
              leaseGeneration: generation,
              nsec: community.nsec!,
              memberPubkey: memberPubkey,
              subscriptions: community.pushSubscriptionState.desired,
              submit:
                  ({
                    required kind,
                    required content,
                    required tags,
                    createdAt,
                  }) => submitSignedEventOnce(
                    wsUrl: canonicalBuzzPushRelayOrigin(community.relayUrl),
                    nsec: community.nsec!,
                    kind: kind,
                    content: content,
                    tags: tags,
                    createdAt: createdAt,
                  ),
            );
            if (cancelled) return;
            if (await notifier.markPushLeaseAccepted(
              community.id,
              subscriptions: community.pushSubscriptionState.desired,
              generation: generation,
            )) {
              accepted.value[community.id] = (
                fingerprint: key,
                renewAt: endpoint.expiresAt - 600,
                generation: generation,
              );
            }
          } on Object {
            failed = true;
          }
        }
        if (!cancelled) {
          androidPushError.value = failed
              ? 'Notifications are waiting for relay or push service connectivity.'
              : null;
          await ref
              .read(buzzPushAuthorizationStatusProvider.notifier)
              .refresh();
          // Repair a previous interrupted wake using the same production query path.
          // Native de-duplication prevents repeated notices across process restarts.
          final prefs = await SharedPreferences.getInstance();
          await prefs.reload();
          if (prefs.getBool(androidPendingWakeKey) == true) {
            await deliverAndroidBuzzWake();
          }
        }
      });
      tail.value = operation.catchError((Object _) {
        // The desired lease and any pending wake remain durable. The next
        // bounded timer/resume tick retries; no credentials enter logs or UI.
        androidPushError.value =
            'Notifications are waiting for relay or push service connectivity.';
      });
      return () => cancelled = true;
    }, [fingerprint, androidPushToken.value, tick.value]);
    return child;
  }
}
