import 'package:buzz/features/settings/settings_page.dart';
import 'package:buzz/shared/community/community.dart';
import 'package:buzz/shared/community/community_provider.dart';
import 'package:buzz/shared/push/android_push_registration.dart';
import 'package:buzz/shared/push/push_bridge.dart';
import 'package:buzz/shared/theme/theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'Android configuration and denied-permission recovery are explicit',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final community = Community.create(
        name: 'Team',
        relayUrl: 'wss://relay.example',
      ).copyWith(pushNotificationsEnabled: true);
      var opened = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            savedPrefsProvider.overrideWithValue(prefs),
            activeCommunityProvider.overrideWith((ref) async => community),
            buzzPushAuthorizationStatusReaderProvider.overrideWithValue(
              () async => BuzzPushAuthorizationStatus.denied,
            ),
            buzzPushNotificationSettingsOpenerProvider.overrideWithValue(
              () async {
                opened++;
                return true;
              },
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: SettingsPage(
              profileHeader: const SizedBox.shrink(),
              invitePageBuilder: (_) => const SizedBox.shrink(),
              identityRecoveryPageBuilder: (_) => const SizedBox.shrink(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (androidPushBuildEnabled) {
        expect(
          find.text('Enabled in Buzz, but disabled in Android Settings'),
          findsOneWidget,
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('push-notifications-open-settings')),
        );
        await tester.tap(
          find.byKey(const ValueKey('push-notifications-open-settings')),
        );
        await tester.pump();
        expect(opened, 1);
      } else {
        expect(find.text('Unavailable in this build'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('push-notifications-enabled')),
          findsNothing,
        );
      }
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
