// Crash and problem reports (Sentry), so failures reach us with details instead of a screenshot.
//
// Off unless the build is given a Sentry address: builds pass SENTRY_DSN from the GitHub secret
// of the same name (Settings > Secrets and variables > Actions). With no secret, nothing is sent
// and nothing changes.
//
// What's sent: crashes, uncaught errors, and playback failures, with the device model, iOS or
// Windows version, Frame's build, and what the player was doing (original or server version,
// Dolby Vision or not). Never sent: your server's sign-in token (removed from every address
// and message below), names of people, or IP addresses.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

const String _dsn = String.fromEnvironment('SENTRY_DSN');
const String _build = String.fromEnvironment('FRAME_BUILD', defaultValue: 'dev');

bool get crashReportsOn => _dsn.isNotEmpty;

/// Starts reporting (when this build has a Sentry address), then runs the app.
Future<void> startWithCrashReports(void Function() runApp) async {
  if (!crashReportsOn) {
    runApp();
    return;
  }
  await SentryFlutter.init(
    (options) {
      options.dsn = _dsn;
      options.release = 'frame@0.3.0+$_build';
      options.environment = kReleaseMode ? 'release' : 'debug';
      options.sendDefaultPii = false;
      options.tracesSampleRate = 0; // problems only, no performance tracing
      options.attachScreenshot = false; // the screen can show your library and names
      options.beforeBreadcrumb = (crumb, hint) => crumb?.copyWith(
            message: crumb.message == null ? null : scrubSecrets(crumb.message!),
            data: crumb.data?.map((k, v) => MapEntry(k, v is String ? scrubSecrets(v) : v)),
          );
      options.beforeSend = (event, hint) => event.copyWith(
            message: event.message == null
                ? null
                : event.message!.copyWith(formatted: scrubSecrets(event.message!.formatted)),
            exceptions: event.exceptions
                ?.map((e) => e.copyWith(value: e.value == null ? null : scrubSecrets(e.value!)))
                .toList(),
          );
    },
    appRunner: runApp,
  );
}

/// Removes sign-in tokens from addresses and headers: "ApiKey=abc123" becomes "ApiKey=…".
String scrubSecrets(String text) => text
    .replaceAllMapped(
      RegExp(r'((?:api_?key|access_?token|token)=)[^&\s"]+', caseSensitive: false),
      (m) => '${m[1]}…',
    )
    .replaceAllMapped(RegExp(r'(Token=")[^"]*(")'), (m) => '${m[1]}…${m[2]}');

/// A problem that didn't crash the app but stopped something working (a video that won't
/// play, say). [details] are short facts that help find the cause.
void reportProblem(String what, {Map<String, Object?> details = const {}}) {
  if (!crashReportsOn) return;
  unawaited(Sentry.captureMessage(
    scrubSecrets(what),
    level: SentryLevel.error,
    withScope: (scope) {
      for (final e in details.entries) {
        final v = e.value;
        scope.setTag(e.key, scrubSecrets(v?.toString() ?? 'none'));
      }
    },
  ));
}
