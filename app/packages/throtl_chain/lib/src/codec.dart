/// Minimal Borsh primitive encoders (little-endian, tightly packed). 64-bit values go through
/// BigInt so encoding is identical on the Dart VM and on the web (where `int` is a JS double).
library;

import 'dart:typed_data';

List<int> u16le(int v) {
  final b = ByteData(2)..setUint16(0, v, Endian.little);
  return b.buffer.asUint8List();
}

List<int> u32le(int v) {
  final b = ByteData(4)..setUint32(0, v, Endian.little);
  return b.buffer.asUint8List();
}

List<int> i32le(int v) {
  final b = ByteData(4)..setInt32(0, v, Endian.little);
  return b.buffer.asUint8List();
}

List<int> u64le(int v) => _bigLe(BigInt.from(v), 8, signed: false);

List<int> i64le(int v) => _bigLe(BigInt.from(v), 8, signed: true);

List<int> _bigLe(BigInt v, int bytes, {required bool signed}) {
  var x = v;
  if (signed && x.isNegative) {
    x = (BigInt.one << (bytes * 8)) + x; // two's complement
  }
  final out = List<int>.filled(bytes, 0);
  for (var i = 0; i < bytes; i++) {
    out[i] = (x & BigInt.from(0xff)).toInt();
    x = x >> 8;
  }
  return out;
}
