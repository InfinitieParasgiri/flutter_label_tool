import 'dart:convert';

import 'package:analyzer/dart/analysis/utilities.dart';

final _tokens = RegExp(r'"(?:[^"\\]|\\.)*"|[{}]', dotAll: true);

/// Decode JSON while checking keys before jsonDecode can discard duplicates.
Map<String, Object?> readCatalog(String source) {
  final decoded = jsonDecode(source);
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('Expected a JSON object at the catalog root.');
  }

  final objects = <Set<String>>[];
  for (final token in _tokens.allMatches(source)) {
    switch (token[0]) {
      case '{':
        objects.add({});
      case '}':
        objects.removeLast();
      default:
        var next = token.end;
        while (next < source.length && ' \t\r\n'.contains(source[next])) {
          next++;
        }
        if (next == source.length || source[next] != ':') continue;
        final key = jsonDecode(token[0]!) as String;
        if (!objects.last.add(key)) {
          throw FormatException(
            'Duplicate catalog key: ${jsonEncode(key)}',
            source,
            token.start,
          );
        }
    }
  }
  return decoded;
}

/// Insert entries into an existing JSON object without reserializing its values.
String appendCatalogEntries(
  String source,
  Map<String, Object?> entries, {
  String? section,
}) {
  var depth = 0;
  var inSection = section == null;
  var close = -1;
  for (final token in _tokens.allMatches(source)) {
    final text = token[0]!;
    if (text == '{') {
      depth++;
    } else if (text == '}') {
      if (inSection && depth == (section == null ? 1 : 2)) {
        close = token.start;
        break;
      }
      depth--;
    } else if (section != null && depth == 1) {
      final following = source.substring(token.end).trimLeft();
      inSection = following.startsWith(':') && jsonDecode(text) == section;
    }
  }
  if (close == -1)
    throw const FormatException('Could not locate the catalog object.');
  final before = source.substring(0, close).trimRight();
  final ending = source.contains('\r\n') ? '\r\n' : '\n';
  final indent = section == null ? '' : '  ';
  final rows = const JsonEncoder.withIndent('  ').convert(entries).split('\n');
  final addition = rows
      .skip(1)
      .take(rows.length - 2)
      .map((row) => '$indent$row')
      .join(ending);
  final comma = before.endsWith('{') ? '' : ',';
  final updated =
      '$before$comma$ending$addition$ending$indent${source.substring(close)}';
  readCatalog(updated);
  return updated;
}

bool isDartName(String name) {
  if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9_]*$').hasMatch(name)) return false;
  final result = parseString(
    content: 'class LabelNames { String get $name => ""; }',
    throwIfDiagnostics: false,
  );
  return result.errors.isEmpty;
}

String _baseKey(String value) {
  final words = RegExp(
    r'[a-zA-Z0-9]+',
  ).allMatches(value).take(6).map((match) => match[0]!.toLowerCase()).toList();
  if (words.isEmpty) return 'label';
  final key =
      words.first +
      words
          .skip(1)
          .map((word) => word[0].toUpperCase() + word.substring(1))
          .join();
  return isDartName(key)
      ? key
      : 'label${key[0].toUpperCase()}${key.substring(1)}';
}

final class Catalog {
  Catalog(this.data, {required this.arb, required this.section})
    : _entries = arb ? data : _section(data, section);

  final Map<String, Object?> data;
  final bool arb;
  final String section;
  final Map<String, Object?> _entries;
  final additions = <String, String>{};

  static Map<String, Object?> _section(
    Map<String, Object?> data,
    String section,
  ) {
    if (!data.containsKey(section)) data[section] = <String, Object?>{};
    final value = data[section];
    if (value is! Map<String, Object?>) {
      throw FormatException('Catalog section "$section" must be an object.');
    }
    return value;
  }

  bool _usable(String key) =>
      isDartName(key) &&
      (!arb ||
          !const {
            'of',
            'delegate',
            'localizationsDelegates',
            'supportedLocales',
            'localeName',
            'hashCode',
            'runtimeType',
            'toString',
            'noSuchMethod',
          }.contains(key));

  bool _reusable(String key) {
    if (!_usable(key)) return false;
    if (!arb) return true;
    final metadata = data['@$key'];
    if (metadata == null) return true;
    return metadata is Map<String, Object?> &&
        (metadata['placeholders'] == null ||
            metadata['placeholders'] is Map &&
                (metadata['placeholders'] as Map<Object?, Object?>).isEmpty);
  }

  String keyFor(String value, {String? requested}) {
    if (requested != null) {
      if (!_usable(requested))
        throw FormatException('Invalid localization key "$requested".');
      if (_entries.containsKey(requested)) {
        if (_entries[requested] == value && _reusable(requested))
          return requested;
        throw FormatException(
          'Key "$requested" already exists with a different value or message format.',
        );
      }
      if (arb && data.containsKey('@$requested')) {
        throw FormatException('Metadata already exists for key "$requested".');
      }
      return _add(requested, value);
    }

    final matches = _entries.entries
        .where(
          (entry) =>
              entry.value == value &&
              _reusable(entry.key) &&
              (!arb || !entry.key.startsWith('@')),
        )
        .toList();
    if (matches.length == 1) return matches.single.key;
    if (matches.length > 1) {
      throw FormatException(
        'Several existing keys have this value (${matches.map((entry) => entry.key).join(', ')}). Select one with --key.',
      );
    }

    final base = _baseKey(value);
    var key = base;
    for (
      var suffix = 2;
      !_usable(key) ||
          _entries.containsKey(key) ||
          arb && data.containsKey('@$key');
      suffix++
    ) {
      key = '$base$suffix';
    }
    return _add(key, value);
  }

  String _add(String key, String value) {
    additions[key] = value;
    _entries[key] = value;
    return key;
  }
}
