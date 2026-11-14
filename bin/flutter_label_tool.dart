import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'package:flutter_label_tool/src/extraction.dart';
import 'package:flutter_label_tool/src/scanner.dart';
import 'package:flutter_label_tool/src/target.dart';

void main(List<String> arguments) {
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false)
    ..addOption('root', defaultsTo: '.', help: 'Flutter project root.')
    ..addMultiOption(
      'source',
      splitCommas: false,
      defaultsTo: ['lib'],
      help: 'Project-relative source directory or Dart file. Repeat as needed.',
    );
  parser.addCommand('scan')
    ..addFlag('check', negatable: false, help: 'Exit 1 when findings exist.')
    ..addFlag('json', negatable: false, help: 'Emit JSON findings.');
  parser.addCommand('extract')
    ..addOption(
      'mode',
      allowed: ['app-labels', 'arb'],
      help: 'Localization destination.',
    )
    ..addOption('catalog', help: 'Override the English JSON or ARB path.')
    ..addOption(
      'import',
      help: 'Override the path to the Dart localization class.',
    )
    ..addOption(
      'section',
      defaultsTo: 'common',
      help: 'AppLabels JSON section.',
    )
    ..addOption('at', help: 'Select one finding using file:line[:column].')
    ..addOption('key', help: 'Use this key for the selected finding.')
    ..addOption(
      'apply',
      help: 'Apply using the token printed by extract preview.',
    );

  try {
    final args = parser.parse(arguments);
    final command = args.command;
    if (args.flag('help') || command == null) {
      stdout.writeln(
        'Usage: flutter_label_tool [options] <scan|extract> [command options]',
      );
      stdout.writeln(parser.usage);
      for (final name in parser.commands.keys) {
        stdout.writeln('\n$name\n${parser.commands[name]!.usage}');
      }
      if (command == null && arguments.isNotEmpty && !args.flag('help'))
        exitCode = 2;
      return;
    }
    if (command.rest.isNotEmpty || args.rest.isNotEmpty) {
      throw const FormatException(
        'Unexpected arguments. Use --help for usage.',
      );
    }

    final root = Directory(args.option('root')!).resolveSymbolicLinksSync();
    if (!File(p.join(root, 'pubspec.yaml')).existsSync()) {
      throw const FormatException(
        'The project root must contain pubspec.yaml.',
      );
    }
    final sources = _readSources(root, args.multiOption('source'));
    final findings = [
      for (final entry in sources.entries)
        ...scanSource(entry.key, entry.value),
    ];

    switch (command.name) {
      case 'scan':
        if (command.flag('json')) {
          stdout.writeln(
            const JsonEncoder.withIndent('  ').convert([
              for (final finding in findings)
                {
                  'path': finding.path,
                  'line': finding.line,
                  'column': finding.column,
                  'site': finding.site,
                  'text': finding.value ?? finding.literal.toSource(),
                  'reviewReason': finding.reason,
                },
            ]),
          );
        } else {
          for (final finding in findings) {
            final reason = finding.reason;
            stdout.writeln(
              '${finding.location} ${finding.site} ${jsonEncode(finding.value ?? finding.literal.toSource())}'
              '${reason == null ? '' : ' [manual: $reason]'}',
            );
          }
          stdout.writeln('${findings.length} hardcoded UI string(s) found.');
        }
        if (command.flag('check') && findings.isNotEmpty) exitCode = 1;
      case 'extract':
        final selected = _select(findings, command.option('at'));
        final section = command.option('section')!;
        if (section.trim().isEmpty)
          throw const FormatException('The section must not be blank.');
        final target = Target.forProject(
          root,
          mode: command.option('mode'),
          catalog: command.option('catalog'),
          lookupImport: command.option('import'),
          section: section,
        );
        final plan = planExtraction(
          target,
          sources,
          selected,
          key: command.option('key'),
        );
        for (final change in plan.preview) {
          stdout.writeln(change);
        }
        for (final skip in plan.skipped) {
          stdout.writeln('Manual review: $skip');
        }
        final token = command.option('apply');
        if (plan.files.isEmpty) {
          if (token != null)
            throw const FormatException(
              'There are no matching edits to apply.',
            );
          stdout.writeln('No automatic edits available.');
        } else if (token == null) {
          stdout.writeln(
            '\nPreview only. Repeat this command with --apply ${plan.token}',
          );
        } else {
          plan.apply(token);
          stdout.writeln('Updated ${plan.files.length} file(s).');
          if (target.arb)
            stdout.writeln('Run flutter gen-l10n in the target project.');
        }
    }
  } on Exception catch (error) {
    stderr.writeln(error);
    exitCode = 2;
  } on ArgumentError catch (error) {
    stderr.writeln(error);
    exitCode = 2;
  }
}

Map<String, String> _readSources(String root, List<String> inputs) {
  final paths = <String>{};
  for (final input in inputs) {
    final path = projectPath(root, input);
    switch (FileSystemEntity.typeSync(path)) {
      case FileSystemEntityType.file:
        paths.add(path);
      case FileSystemEntityType.directory:
        for (final entity in Directory(
          path,
        ).listSync(recursive: true, followLinks: false)) {
          if (entity is File) paths.add(entity.path);
        }
      default:
        throw FormatException('Source not found: $input');
    }
  }
  final files = paths.where((path) {
    final name = p.basename(path);
    return name.endsWith('.dart') &&
        !name.endsWith('.g.dart') &&
        !name.endsWith('.freezed.dart') &&
        !name.startsWith('app_localizations') &&
        !p
            .split(p.relative(path, from: root))
            .any((part) => part.startsWith('.') || part == 'build');
  }).toList()..sort();
  return {
    for (final path in files)
      p.relative(path, from: root): File(path).readAsStringSync(),
  };
}

List<Finding> _select(List<Finding> findings, String? at) {
  if (at == null) return findings;
  final match = RegExp(r'^(.+?):(\d+)(?::(\d+))?$').firstMatch(at);
  if (match == null)
    throw const FormatException('--at expects file:line[:column].');
  final path = p.normalize(match[1]!);
  final line = int.parse(match[2]!);
  final column = int.tryParse(match[3] ?? '');
  final selected = findings
      .where(
        (finding) =>
            finding.path == path &&
            finding.line == line &&
            (column == null || finding.column == column),
      )
      .toList();
  if (selected.length != 1) {
    throw const FormatException(
      '--at must match exactly one finding. Use the complete file:line:column from scan.',
    );
  }
  return selected;
}
