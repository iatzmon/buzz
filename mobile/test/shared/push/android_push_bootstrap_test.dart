import 'package:buzz/shared/push/android_push_bootstrap.dart';
import 'package:buzz/shared/push/push_subscription.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('opt-out tombstone invalidates the cached lease before re-enabling', () {
    final subscriptions = [
      BuzzPushSubscription(
        filter: BuzzPushFilter(kinds: [9], pTags: ['a' * 64]),
        notificationClass: 'default',
      ),
    ];
    final active = BuzzPushLeaseSubscriptionState.desired(
      desired: subscriptions,
    ).withAccepted(subscriptions: subscriptions, generation: 3);
    expect(androidPushLeaseGenerationIsCurrent(active, 3), isTrue);

    final disabled = active.withPendingTombstone(4);
    expect(androidPushLeaseGenerationIsCurrent(disabled, 3), isFalse);
    final revoked = disabled.withAcceptedTombstone(4);
    expect(androidPushLeaseGenerationIsCurrent(revoked, 3), isFalse);
    expect(androidPushLeaseGenerationIsCurrent(revoked, 4), isFalse);

    final renewed = revoked
        .withReservedGeneration(5)
        .withAccepted(subscriptions: subscriptions, generation: 5);
    expect(androidPushLeaseGenerationIsCurrent(renewed, 5), isTrue);
    expect(androidPushLeaseGenerationIsCurrent(renewed, 3), isFalse);
  });
}
