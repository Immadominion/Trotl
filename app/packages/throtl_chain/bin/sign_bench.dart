// M0.2 — ed25519 sign budget for the tick hot path. Signs a ~200-byte legacy-tx-sized payload with
// the SAME signer the tick loop uses (Ed25519HDKeyPair.sign) and reports the per-sign distribution.
// The bar: p99 < 2ms (so signing never dominates a 30Hz tick frame), especially on web.
//
//   dart run throtl_chain:sign_bench           # Dart VM (native) baseline
//   dart compile js bin/sign_bench.dart -o /tmp/sb.js && node /tmp/sb.js   # dart2js (web) number
// ignore_for_file: avoid_print — CLI benchmark output.
import 'dart:typed_data';

import 'package:solana/solana.dart';

Future<void> main() async {
  final kp = await Ed25519HDKeyPair.random();
  final msg = Uint8List.fromList(List<int>.generate(200, (i) => (i * 7 + 3) & 0xff));

  // warm up (JIT / WebCrypto handshake)
  for (var i = 0; i < 50; i++) {
    await kp.sign(msg);
  }

  const n = 1000;
  final samples = <double>[];
  for (var i = 0; i < n; i++) {
    final sw = Stopwatch()..start();
    await kp.sign(msg);
    sw.stop();
    samples.add(sw.elapsedMicroseconds / 1000.0); // ms
  }
  samples.sort();
  double pct(int p) => samples[((samples.length - 1) * p / 100).floor()];

  print('ed25519 sign of 200B over $n iters:');
  print(
    '  p50=${pct(50).toStringAsFixed(3)}ms  p90=${pct(90).toStringAsFixed(3)}ms  '
    'p99=${pct(99).toStringAsFixed(3)}ms  max=${samples.last.toStringAsFixed(3)}ms',
  );
  final ok = pct(99) < 2.0;
  print(
    '  bar p99 < 2ms: ${ok ? 'PASS' : 'FAIL (use WebCrypto Ed25519 on web — architecture R5 mitigation)'}',
  );
}
