import 'dart:convert';

import 'package:xml/xml.dart';

import 'core.dart';

dynamic decodePlist(String source) {
  final root = XmlDocument.parse(source).rootElement;
  return _decode(root.name.local == 'plist' ? root.childElements.single : root);
}

dynamic _decode(XmlElement element) {
  switch (element.name.local) {
    case 'dict':
      final children = element.childElements.toList();
      if (children.length.isOdd) fail('invalid plist dictionary');
      final result = <String, dynamic>{};
      for (var i = 0; i < children.length; i += 2) {
        if (children[i].name.local != 'key' ||
            result.containsKey(children[i].innerText))
          fail('invalid plist key');
        result[children[i].innerText] = _decode(children[i + 1]);
      }
      return result;
    case 'array':
      return element.childElements.map(_decode).toList();
    case 'string':
      return element.innerText;
    case 'integer':
      return int.parse(element.innerText);
    case 'real':
      return double.parse(element.innerText);
    case 'true':
      return true;
    case 'false':
      return false;
    case 'data':
      return base64Decode(
        element.innerText.replaceAll(RegExp(r'\s'), ' ').replaceAll(' ', ''),
      );
    case 'date':
      return DateTime.parse(element.innerText);
    default:
      fail('unsupported plist element');
  }
}

String encodePlist(dynamic value) {
  final builder = XmlBuilder();
  builder.processing('xml', 'version="1.0" encoding="UTF-8"');
  builder.doctype(
    'plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"',
  );
  builder.element(
    'plist',
    attributes: {'version': '1.0'},
    nest: () => _encode(builder, value),
  );
  return '${builder.buildDocument().toXmlString(pretty: true)}\n';
}

void _encode(XmlBuilder b, dynamic value) {
  if (value is Map<String, dynamic>) {
    b.element(
      'dict',
      nest: () {
        final keys = value.keys.cast<String>().toList()..sort();
        for (final key in keys) {
          b.element('key', nest: key);
          _encode(b, value[key]);
        }
      },
    );
  } else if (value is List<int>) {
    b.element('data', nest: base64Encode(value));
  } else if (value is List<dynamic>) {
    b.element(
      'array',
      nest: () {
        for (final v in value) {
          _encode(b, v);
        }
      },
    );
  } else if (value is bool) {
    b.element(value ? 'true' : 'false');
  } else if (value is int) {
    b.element('integer', nest: '$value');
  } else if (value is double) {
    b.element('real', nest: '$value');
  } else if (value is DateTime) {
    b.element('date', nest: value.toUtc().toIso8601String());
  } else if (value is String) {
    b.element('string', nest: value);
  } else {
    fail('unsupported plist value');
  }
}
