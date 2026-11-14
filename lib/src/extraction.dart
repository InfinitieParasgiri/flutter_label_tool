import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'catalog.dart';
import 'scanner.dart';
import 'target.dart';

typedef FileEdit = ({String path, String before, String after});
typedef _SourceEdit = ({int offset, int end, String replacement});

final class Extraction {
  Extraction(this.files, this.preview, this.skipped);

  final List<FileEdit> files;
  final List<String> preview;
  final List<String> skipped;

  String get token => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            for (final file in files) [file.path, file.before, file.after],
          ]),
        ),
      )
      .toString();

  void apply(String reviewedToken) {
    if (reviewedToken != token) {
      throw const FormatException(
        'Preview token does not match. Run extract again and review the new plan.',
      );
    }
    final staged = <String, File>{};
    final applied = <FileEdit>[];
    final stagingDirectories = <Directory>[];
    try {
      for (final edit in files) {
        if (File(edit.path).readAsStringSync() != edit.before) {
          throw FormatException('File changed since preview: ${edit.path}');
        }
        final staging = Directory(
          p.join(p.dirname(edit.path), '.'),
        ).createTempSync('.flutter_label_tool_');
        stagingDirectories.add(staging);
        staged[edit.path] = File(p.join(staging.path, 'new'))
          ..writeAsStringSync(edit.after, flush: true);
      }
      for (final edit in files) {
        staged[edit.path]!.renameSync(edit.path);
        applied.add(edit);
      }
    } catch (_) {
      for (final edit in applied.reversed) {
        File(edit.path).writeAsStringSync(edit.before, flush: true);
      }
      rethrow;
    } finally {
      for (final staging in stagingDirectories) {
        staging.deleteSync(recursive: true);
      }
    }
  }
}

Extraction planExtraction(
  Target target,
  Map<String, String> sources,
  List<Finding> findings, {
  String? key,
}) {
  if (key != null && findings.length != 1) {
    throw const FormatException(
      '--key requires selecting exactly one finding with --at.',
    );
  }
  if (!isDartName(target.className)) {
    throw FormatException('Invalid localization class: ${target.className}');
  }
  if (target.mode == Mode.appLabels && !File(target.importPath).existsSync()) {
    throw FormatException(
      'AppLabels Dart file not found: ${target.importPath}',
    );
  }

  final catalogFile = File(target.catalogPath);
  final catalogSource = catalogFile.readAsStringSync();
  final originalCatalog = readCatalog(catalogSource);
  final hasSection = originalCatalog.containsKey(target.section);
  final catalog = Catalog(
    originalCatalog,
    arb: target.arb,
    section: target.section,
  );
  final preview = <String>[];
  final skipped = <String>[];
  final sourceEdits = <String, List<_SourceEdit>>{};
  final imports = <String, String>{};

  for (final finding in findings) {
    final value = finding.value;
    String? reason = finding.reason;
    if (value != null && target.arb) {
      if (value.contains('{') ||
          value.contains('}') ||
          target.useEscaping && value.contains("'")) {
        reason ??= 'ARB message uses ICU syntax or escaping';
      }
    }
    if (reason != null || value == null || finding.context == null) {
      skipped.add(
        '${finding.location}: ${reason ?? 'requires manual extraction'}',
      );
      continue;
    }
    final source = sources[finding.path]!;
    final prefix = imports.putIfAbsent(
      finding.path,
      () => _freshPrefix(source),
    );
    final labelKey = catalog.keyFor(value, requested: key);
    final unwrap = target.nullableGetter ? '!' : '';
    final lookup = target.arb
        ? '$prefix.${target.className}.of(${finding.context})$unwrap.$labelKey'
        : '$prefix.AppLabels.text(${finding.context}, ${_dartString(target.section)}, ${_dartString(labelKey)})';
    preview.add(
      '${finding.location}: ${jsonEncode(finding.literal.toSource())} → $lookup',
    );
    (sourceEdits[finding.path] ??= []).add((
      offset: finding.literal.offset,
      end: finding.literal.end,
      replacement: lookup,
    ));
  }

  final files = <FileEdit>[];
  if (catalog.additions.isNotEmpty) {
    final additions = <String, Object?>{
      for (final entry in catalog.additions.entries) ...{
        entry.key: entry.value,
        if (target.arbMetadata)
          '@${entry.key}': {
            'description': 'UI label extracted from Dart source.',
          },
      },
    };
    preview.insertAll(0, [
      '${p.relative(target.catalogPath, from: target.root)} additions:',
      for (final entry in additions.entries)
        '  ${target.arb ? entry.key : '${target.section}.${entry.key}'} = ${jsonEncode(entry.value)}',
    ]);
    final updatedCatalog = target.arb
        ? appendCatalogEntries(catalogSource, additions)
        : hasSection
        ? appendCatalogEntries(
            catalogSource,
            additions,
            section: target.section,
          )
        : appendCatalogEntries(catalogSource, {target.section: additions});
    files.add((
      path: target.catalogPath,
      before: catalogSource,
      after: updatedCatalog,
    ));
  }

  for (final entry in sourceEdits.entries) {
    final source = sources[entry.key]!;
    final absolute = projectPath(target.root, entry.key);
    if (absolute == target.importPath || absolute == target.catalogPath) {
      throw FormatException(
        'Cannot extract from the localization implementation or catalog: ${entry.key}',
      );
    }
    final unit = parseString(content: source).unit;
    final directive = _importDirective(
      unit,
      source,
      absolute,
      target.importPath,
      imports[entry.key]!,
    );
    preview.add('${entry.key}: add ${directive.replacement.trim()}');
    final edits = [...entry.value, directive]
      ..sort((a, b) => b.offset.compareTo(a.offset));
    var updated = source;
    for (final edit in edits) {
      updated = updated.replaceRange(edit.offset, edit.end, edit.replacement);
    }
    parseString(content: updated, path: absolute);
    files.add((path: absolute, before: source, after: updated));
  }
  return Extraction(files, preview, skipped);
}

String _freshPrefix(String source) {
  const base = 'labelToolL10n';
  var prefix = base;
  for (
    var i = 2;
    RegExp('\\b${RegExp.escape(prefix)}\\b').hasMatch(source);
    i++
  ) {
    prefix = '$base$i';
  }
  return prefix;
}

_SourceEdit _importDirective(
  CompilationUnit unit,
  String source,
  String path,
  String target,
  String prefix,
) {
  final relative = p
      .relative(target, from: p.dirname(path))
      .split(p.separator)
      .join('/');
  final uri = Uri(path: relative).toString();
  final import = 'import ${_dartString(uri)} as $prefix;';
  final lineBreak = source.contains('\r\n') ? '\r\n' : '\n';
  // Insert before the first import/export/part or declaration, after any library directive.
  final following =
      unit.directives
          .where((directive) => directive is! LibraryDirective)
          .firstOrNull ??
      unit.declarations.first;
  final offset =
      following.beginToken.precedingComments?.offset ?? following.offset;
  final library = unit.directives.whereType<LibraryDirective>().lastOrNull;
  if (library != null && offset < library.end) {
    return (
      offset: library.end,
      end: library.end,
      replacement: '$lineBreak$import$lineBreak',
    );
  }
  return (offset: offset, end: offset, replacement: '$import$lineBreak');
}

String _dartString(String value) => jsonEncode(value).replaceAll(r'$', r'\$');
