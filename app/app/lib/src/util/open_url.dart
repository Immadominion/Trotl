import 'dart:async';

import 'package:url_launcher/url_launcher.dart';

/// Open [url] in a new browser tab (web) / the external browser (mobile).
/// Fire-and-forget so it drops cleanly into a button's `onTap`; a failure to
/// launch (blocked popup / no handler) is swallowed rather than crashing the UI.
void openUrl(String url) => unawaited(_launch(url));

Future<void> _launch(String url) async {
  try {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } on Object {
    // no handler / blocked — nothing to do
  }
}
