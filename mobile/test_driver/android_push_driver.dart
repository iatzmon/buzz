import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

const _package = 'xyz.block.buzz.mobile';
const _serial = 'emulator-5554';
const _defaultEvidence = 'build/android-push-evidence';

Future<void> main() async {
  final evidencePath =
      Platform.environment['BUZZ_ANDROID_EVIDENCE'] ?? _defaultEvidence;
  final evidence = Directory(evidencePath)..createSync(recursive: true);
  final log = File('${evidence.path}/driver.log').openWrite();
  final sdkRoot = Platform.environment['ANDROID_SDK_ROOT'];
  final adb =
      Platform.environment['ANDROID_ADB'] ??
      (sdkRoot == null
          ? '/opt/homebrew/bin/adb'
          : '$sdkRoot/platform-tools/adb');

  Future<ProcessResult> runAdb(List<String> args) async {
    final result = await Process.run(adb, ['-s', _serial, ...args]);
    log.writeln('adb ${args.join(' ')} -> ${result.exitCode}');
    if ((result.stdout as String).isNotEmpty) log.writeln(result.stdout);
    if ((result.stderr as String).isNotEmpty) log.writeln(result.stderr);
    return result;
  }

  await runAdb(['logcat', '-c']);

  final orchestration = _backgroundAndTap(
    adb: adb,
    evidence: evidence,
    log: log,
  );
  try {
    await integrationDriver(
      onScreenshot: (name, bytes, [args]) async {
        await File('${evidence.path}/$name.png').writeAsBytes(bytes);
        return true;
      },
      responseDataCallback: (data) async {
        await File(
          '${evidence.path}/integration-response.json',
        ).writeAsString(const JsonEncoder.withIndent('  ').convert(data));
      },
      writeResponseOnFailure: true,
    );
  } finally {
    await orchestration;
    await runAdb(['shell', 'dumpsys', 'notification', '--noredact']).then(
      (result) => File(
        '${evidence.path}/notification-final.txt',
      ).writeAsString(result.stdout as String),
    );
    await _capture(adb, evidence, 'screen-final.png');
    final logcat = await runAdb(['logcat', '-d', '-v', 'threadtime']);
    await File(
      '${evidence.path}/logcat.txt',
    ).writeAsString(logcat.stdout as String);
    await log.flush();
    await log.close();
  }
}

Future<void> _backgroundAndTap({
  required String adb,
  required Directory evidence,
  required IOSink log,
}) async {
  await _denyPermissionThenGrant(adb, evidence, log);

  final markerDeadline = DateTime.now().add(const Duration(seconds: 30));
  var markerSeen = false;
  while (!markerSeen && DateTime.now().isBefore(markerDeadline)) {
    final result = await Process.run(adb, [
      '-s',
      _serial,
      'logcat',
      '-d',
      '-v',
      'brief',
    ]);
    final output = result.stdout as String;
    markerSeen = output.contains('ANDROID_PUSH_BACKGROUND_READY');
    if (!markerSeen) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  }
  if (!markerSeen) {
    throw StateError(
      'The integration app never reached the background-ready marker.',
    );
  }

  await Process.run(adb, [
    '-s',
    _serial,
    'shell',
    'input',
    'keyevent',
    'KEYCODE_HOME',
  ]);
  log.writeln('sent HOME after ANDROID_PUSH_BACKGROUND_READY');

  final notificationDeadline = DateTime.now().add(const Duration(seconds: 30));
  String dump = '';
  while (DateTime.now().isBefore(notificationDeadline)) {
    final result = await Process.run(adb, [
      '-s',
      _serial,
      'shell',
      'dumpsys',
      'notification',
      '--noredact',
    ]);
    dump = result.stdout as String;
    if (dump.contains(_package) && dump.contains('buzz.messages')) break;
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  await File(
    '${evidence.path}/notification-before-tap.txt',
  ).writeAsString(dump);
  if (!dump.contains(_package)) {
    throw StateError(
      'No Buzz notification was posted before the tap window expired.',
    );
  }

  await _capture(adb, evidence, 'screen-before-tap.png');
  await Process.run(adb, [
    '-s',
    _serial,
    'shell',
    'input',
    'swipe',
    '540',
    '80',
    '540',
    '1700',
    '500',
  ]);
  await Future<void>.delayed(const Duration(seconds: 1));
  await _capture(adb, evidence, 'notification-shade-before-tap.png');
  // The fixture posts one notification. The first row in the unlocked API 36
  // shade is therefore the notification rendered by BuzzPushNotificationRenderer.
  await Process.run(adb, [
    '-s',
    _serial,
    'shell',
    'input',
    'tap',
    '540',
    '700',
  ]);
  await Future<void>.delayed(const Duration(seconds: 2));
  await _capture(adb, evidence, 'screen-after-tap.png');

  final resumed = await Process.run(adb, [
    '-s',
    _serial,
    'shell',
    'dumpsys',
    'activity',
    'activities',
  ]);
  await File(
    '${evidence.path}/activity-after-tap.txt',
  ).writeAsString(resumed.stdout as String);
  final notificationAfterTap = await Process.run(adb, [
    '-s',
    _serial,
    'shell',
    'dumpsys',
    'notification',
    '--noredact',
  ]);
  await File(
    '${evidence.path}/notification-after-tap.txt',
  ).writeAsString(notificationAfterTap.stdout as String);
  final logcat = await Process.run(adb, [
    '-s',
    _serial,
    'logcat',
    '-d',
    '-v',
    'threadtime',
  ]);
  await File(
    '${evidence.path}/logcat.txt',
  ).writeAsString(logcat.stdout as String);
  log.writeln('warm tap issued; activity state captured');
}

Future<void> _denyPermissionThenGrant(
  String adb,
  Directory evidence,
  IOSink log,
) async {
  final dialogDeadline = DateTime.now().add(const Duration(seconds: 25));
  var markerSeen = false;
  while (!markerSeen && DateTime.now().isBefore(dialogDeadline)) {
    final result = await Process.run(adb, [
      '-s',
      _serial,
      'logcat',
      '-d',
      '-v',
      'brief',
    ]);
    markerSeen = (result.stdout as String).contains(
      'ANDROID_PUSH_PERMISSION_DIALOG',
    );
    if (!markerSeen) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  }
  if (!markerSeen) {
    throw StateError(
      'The integration app never requested notification permission.',
    );
  }

  await Future<void>.delayed(const Duration(seconds: 1));
  final dumpResult = await Process.run(adb, [
    '-s',
    _serial,
    'shell',
    'uiautomator',
    'dump',
    '/sdcard/buzz-permission-dialog.xml',
  ]);
  final xmlResult = await Process.run(adb, [
    '-s',
    _serial,
    'shell',
    'cat',
    '/sdcard/buzz-permission-dialog.xml',
  ]);
  final xml = xmlResult.stdout as String;
  await File('${evidence.path}/permission-dialog-ui.xml').writeAsString(xml);
  await _capture(adb, evidence, 'permission-dialog-before-deny.png');
  log.writeln('permission dialog dump: ${dumpResult.stdout}');
  final node = xml
      .split('<node')
      .firstWhere(
        (value) =>
            value.toLowerCase().contains('allow') &&
            (value.toLowerCase().contains('don') ||
                value.toLowerCase().contains('not')),
        orElse: () => '',
      );
  final bounds = RegExp(
    r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"',
  ).firstMatch(node);
  final x = bounds == null
      ? 540
      : (int.parse(bounds.group(1)!) + int.parse(bounds.group(3)!)) ~/ 2;
  final y = bounds == null
      ? 1480
      : (int.parse(bounds.group(2)!) + int.parse(bounds.group(4)!)) ~/ 2;
  await Process.run(adb, ['-s', _serial, 'shell', 'input', 'tap', '$x', '$y']);
  log.writeln('denied notification permission at ($x,$y)');

  final deniedDeadline = DateTime.now().add(const Duration(seconds: 20));
  var deniedMarkerSeen = false;
  while (!deniedMarkerSeen && DateTime.now().isBefore(deniedDeadline)) {
    final result = await Process.run(adb, [
      '-s',
      _serial,
      'logcat',
      '-d',
      '-v',
      'brief',
    ]);
    deniedMarkerSeen = (result.stdout as String).contains(
      'ANDROID_PUSH_PERMISSION_DENIED',
    );
    if (!deniedMarkerSeen) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  }
  if (!deniedMarkerSeen) {
    throw StateError('The integration app did not observe permission denial.');
  }

  await Process.run(adb, [
    '-s',
    _serial,
    'shell',
    'pm',
    'grant',
    _package,
    'android.permission.POST_NOTIFICATIONS',
  ]);
  await Future<void>.delayed(const Duration(seconds: 1));
  await _capture(adb, evidence, 'permission-after-grant.png');
  log.writeln('granted POST_NOTIFICATIONS after production denied-wake gate');
  return;
}

Future<void> _capture(String adb, Directory evidence, String name) async {
  final process = await Process.start(adb, [
    '-s',
    _serial,
    'exec-out',
    'screencap',
    '-p',
  ]);
  final bytes = await process.stdout.expand((chunk) => chunk).toList();
  await process.stderr.drain<void>();
  await process.exitCode;
  await File('${evidence.path}/$name').writeAsBytes(bytes);
}
