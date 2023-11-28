import 'dart:convert';
import 'dart:typed_data';
import 'package:lib5/src/model/multibase.dart';
import 'package:thirds/blake3.dart';

const CID_PREFIX = [
  0x01, // version
  0x55, // raw codec
  0x1e, // hash function, blake3
  0x20, // hash size, 32 bytes
];

String makeCID(String input) {
  return IpfsCid(
    Uint8List.fromList(
      CID_PREFIX + blake3(utf8.encode(input)),
    ),
  ).toBase32();
}

String makeRKey(String url) {
  return IpfsCid(
    Uint8List.fromList(
      blake3(utf8.encode(url)),
    ),
  ).toBase64Url().substring(0, 15);
}

class IpfsCid extends Multibase {
  final Uint8List bytes;
  IpfsCid(this.bytes);

  @override
  Uint8List toBytes() => bytes;
}
