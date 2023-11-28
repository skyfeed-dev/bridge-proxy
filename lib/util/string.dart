import 'dart:convert';
import 'dart:typed_data';

import 'package:base_codecs/base_codecs.dart';
import 'package:thirds/blake3.dart';

String encodeString(String input) {
  // TODO Performance
  return base32RfcEncode(
    Uint8List.fromList(
      utf8.encode(input),
    ),
  ).toLowerCase().replaceAll('=', '');
}

String decodeString(String input) {
  // TODO Performance
  return utf8.decode(base32RfcDecode(input));
}
