import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

enum Mode { appLabels, arb }

final class Target {
  const Target(
    this.root,
    this.mode,
    this.catalogPath,
    this.importPath,
    this.className,
    this.section,
    this.useEscaping, {
    this.nullableGetter = true,
    this.arbMetadata = false,
  });

  final String root;
  final Mode mode;
  final String catalogPath;
  final String importPath;
  final String className;
  final String section;
  final bool useEscaping;
  final bool nullableGetter;
  final bool arbMetadata;

  bool get arb => mode == Mode.arb;

  static Target forProject(
    String root, {
    String? mode,
    String? catalog,
    String? lookupImport,
    required String section,
  }) {
    final config = File(p.join(root, 'l10n.yaml'));
    final hasAppLabels = File(
      p.join(root, 'lib/utils/app_labels.dart'),
    ).existsSync();
    final hasArb =
        config.existsSync() ||
        File(p.join(root, 'lib/l10n/app_en.arb')).existsSync();
    if (mode == null && hasAppLabels && hasArb) {
      throw const FormatException(
        'Both systems are configured. Choose --mode app-labels or --mode arb.',
      );
    }
    if (mode == 'app-labels' || mode == null && (hasAppLabels || !hasArb)) {
      return Target(
        root,
        Mode.appLabels,
        projectPath(root, catalog ?? 'languages/en.json'),
        projectPath(root, lookupImport ?? 'lib/utils/app_labels.dart'),
        'AppLabels',
        section,
        false,
      );
    }

    final Object? yaml = config.existsSync()
        ? loadYaml(config.readAsStringSync())
        : null;
    if (yaml != null && yaml is! YamlMap) {
      throw const FormatException('l10n.yaml must contain a mapping.');
    }
    final options = yaml as YamlMap?;
    String option(String name, String fallback) {
      final Object? value = options?[name];
      if (value == null) return fallback;
      if (value is! String || value.isEmpty)
        throw FormatException('Invalid l10n.yaml option "$name".');
      return value;
    }

    if (options?['synthetic-package'] == true && lookupImport == null) {
      throw const FormatException(
        'Use --import with the project-relative generated localization file.',
      );
    }
    final arbDir = option('arb-dir', 'lib/l10n');
    final outputDir = option('output-dir', arbDir);
    return Target(
      root,
      Mode.arb,
      projectPath(
        root,
        catalog ?? p.join(arbDir, option('template-arb-file', 'app_en.arb')),
      ),
      projectPath(
        root,
        lookupImport ??
            p.join(
              outputDir,
              option('output-localization-file', 'app_localizations.dart'),
            ),
      ),
      option('output-class', 'AppLocalizations'),
      section,
      options?['use-escaping'] == true,
      nullableGetter: options?['nullable-getter'] != false,
      arbMetadata: options?['required-resource-attributes'] == true,
    );
  }
}

/// Keep write targets inside the project, without following a linked ancestor.
String projectPath(String root, String value) {
  final path = p.normalize(p.absolute(root, value));
  if (!p.isWithin(root, path))
    throw FormatException('Path must be inside the project: $value');
  var current = path;
  while (current != root) {
    if (FileSystemEntity.typeSync(current, followLinks: false) ==
        FileSystemEntityType.link) {
      throw FormatException('Symbolic links are skipped: $value');
    }
    current = p.dirname(current);
  }
  return path;
}
