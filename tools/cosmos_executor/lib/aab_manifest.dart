import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:xml/xml.dart';

import 'core.dart';

void verifyAabManifest(List<String> args) {
  if (args.isEmpty) fail('aab-manifest requires a manifest path');
  final file = File(args[0]);
  if (!file.existsSync()) fail('AAB manifest missing: ${args[0]}');
  final bytes = file.readAsBytesSync();
  if (bytes.isEmpty) fail('AAB manifest is empty');

  final info = _looksLikeXml(bytes)
      ? _parseXmlManifest(bytes)
      : _parseProtoManifest(bytes);
  final expectedPackage = args.length > 1 ? args[1] : '';
  final expectedVersionName = args.length > 2 ? args[2] : '';
  final expectedVersionCode = args.length > 3 ? args[3] : '';

  if (expectedPackage.isNotEmpty && info.packageName != expectedPackage) {
    fail('AAB package mismatch: got ${info.packageName} expected $expectedPackage');
  }
  if (expectedVersionName.isNotEmpty &&
      info.versionName != expectedVersionName) {
    fail(
      'AAB versionName mismatch: got ${info.versionName} expected $expectedVersionName',
    );
  }
  if (expectedVersionCode.isNotEmpty &&
      info.versionCode != expectedVersionCode) {
    fail(
      'AAB versionCode mismatch: got ${info.versionCode} expected $expectedVersionCode',
    );
  }
}

bool _looksLikeXml(Uint8List bytes) {
  for (final byte in bytes) {
    if (byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D) continue;
    return byte == 0x3C;
  }
  return false;
}

({String packageName, String versionName, String versionCode})
_parseXmlManifest(Uint8List bytes) {
  final XmlElement root;
  try {
    root = XmlDocument.parse(utf8.decode(bytes)).rootElement;
  } on Object {
    fail('invalid XML AndroidManifest.xml');
  }
  if (root.name.local != 'manifest') fail('root element is not manifest');
  return (
    packageName: root.getAttribute('package') ?? '',
    versionName:
        root.getAttribute('android:versionName') ??
        root.getAttribute('versionName') ??
        '',
    versionCode:
        root.getAttribute('android:versionCode') ??
        root.getAttribute('versionCode') ??
        '',
  );
}

({String packageName, String versionName, String versionCode})
_parseProtoManifest(Uint8List bytes) {
  final rootFields = _parseProtoFields(bytes);
  final elementList = rootFields[1];
  if (elementList == null || elementList.isEmpty) {
    fail('invalid AAB protobuf manifest: missing root XmlElement');
  }
  final elementFields = _parseProtoFields(elementList.first as Uint8List);
  final elementName = _decodeStringField(elementFields[3]);
  if (elementName != 'manifest') {
    fail('invalid AAB protobuf manifest: root element is $elementName');
  }

  var packageName = '';
  var versionName = '';
  var versionCode = '';
  for (final rawAttr in elementFields[4] ?? const <Object>[]) {
    final attrFields = _parseProtoFields(rawAttr as Uint8List);
    final name = _decodeStringField(attrFields[2]);
    var value = _decodeStringField(attrFields[3]);
    final resourceId = (attrFields[5]?.first as int?) ?? 0;
    if (value.isEmpty && attrFields[6] != null) {
      value = _extractCompiledItemValue(attrFields[6]!.first as Uint8List);
    }
    if (name == 'package') {
      packageName = value;
    } else if (name == 'versionName' || resourceId == 0x0101021c) {
      versionName = value;
    } else if (name == 'versionCode' || resourceId == 0x0101021b) {
      versionCode = value;
    }
  }
  return (
    packageName: packageName,
    versionName: versionName,
    versionCode: versionCode,
  );
}

String _extractCompiledItemValue(Uint8List itemBytes) {
  final itemFields = _parseProtoFields(itemBytes);
  if (itemFields[7] != null) {
    final primFields = _parseProtoFields(itemFields[7]!.first as Uint8List);
    if (primFields[6] != null) {
      return (primFields[6]!.first as int).toSigned(32).toString();
    }
    if (primFields[7] != null) {
      return (primFields[7]!.first as int).toUnsigned(32).toString();
    }
  }
  final strList = itemFields[2] ?? itemFields[3];
  if (strList != null && strList.isNotEmpty) {
    final strFields = _parseProtoFields(strList.first as Uint8List);
    return _decodeStringField(strFields[1]);
  }
  return '';
}

String _decodeStringField(List<Object>? values) {
  if (values == null || values.isEmpty) return '';
  try {
    return utf8.decode(values.first as Uint8List);
  } on Object {
    fail('invalid UTF-8 in AAB protobuf manifest');
  }
}

Map<int, List<Object>> _parseProtoFields(Uint8List bytes) {
  final result = <int, List<Object>>{};
  var offset = 0;

  int readVarint() {
    var value = 0;
    var shift = 0;
    while (offset < bytes.length) {
      final b = bytes[offset++];
      value |= (b & 0x7F) << shift;
      if ((b & 0x80) == 0) return value;
      shift += 7;
      if (shift > 63) fail('malformed varint in AAB protobuf manifest');
    }
    fail('unexpected EOF in AAB protobuf manifest');
  }

  while (offset < bytes.length) {
    final tag = readVarint();
    final fieldNumber = tag >> 3;
    final wireType = tag & 0x07;
    if (fieldNumber <= 0) fail('invalid field number in AAB protobuf manifest');
    switch (wireType) {
      case 0:
        result.putIfAbsent(fieldNumber, () => <Object>[]).add(readVarint());
      case 1:
        if (offset + 8 > bytes.length) fail('truncated fixed64 in AAB manifest');
        offset += 8;
      case 2:
        final len = readVarint();
        if (len < 0 || offset + len > bytes.length) {
          fail('truncated length-delimited field in AAB manifest');
        }
        result
            .putIfAbsent(fieldNumber, () => <Object>[])
            .add(Uint8List.sublistView(bytes, offset, offset + len));
        offset += len;
      case 5:
        if (offset + 4 > bytes.length) fail('truncated fixed32 in AAB manifest');
        offset += 4;
      default:
        fail('unsupported protobuf wire type $wireType in AAB manifest');
    }
  }
  return result;
}
