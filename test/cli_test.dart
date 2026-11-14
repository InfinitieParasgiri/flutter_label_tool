import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory project;
  final tool = p.absolute('bin/flutter_label_tool.dart');
  final packages = p.absolute('.dart_tool/package_config.json');

  File write(String path, String source) {
    final file = File(p.join(project.path, path));
    file.parent.createSync(recursive: true);
    return file..writeAsStringSync(source);
  }

  Future<ProcessResult> run(List<String> options) => Process.run(
    Platform.resolvedExecutable,
    ['--packages=$packages', tool, '--root', project.path, ...options],
  );

  setUp(() {
    project = Directory.systemTemp.createTempSync('flutter_label_tool_test_');
    write('pubspec.yaml', 'name: sample\n');
  });

  tearDown(() => project.deleteSync(recursive: true));

  test(
    'scan finds UI text and reports unsafe edits without matching logs or punctuation',
    () async {
      write('lib/screen.dart', r'''
Widget build(BuildContext context) {
  print('Log message');
  return Column(children: [
    const Text('Constant label'),
    Text('Welcome $name'),
    Text('$name'),
    Text(' · '),
    Tooltip(message: 'Open settings', child: Text('Settings')),
  ]);
}
''');
      final scan = await run(['scan', '--check', '--json']);
      expect(scan.exitCode, 1, reason: '${scan.stderr}');
      final results = jsonDecode(scan.stdout as String) as List<Object?>;
      expect(results, hasLength(4));
      expect(results[0], containsPair('reviewReason', 'const expression'));
      expect(results[1], containsPair('reviewReason', 'interpolated message'));
      expect(results[2], containsPair('site', 'Tooltip.message'));
      expect(results[3], containsPair('text', 'Settings'));
    },
  );

  test('AppLabels preview, stale token, reuse, collision, and apply', () async {
    write('lib/utils/app_labels.dart', 'abstract class AppLabels {}\n');
    const original = '''
class Screen extends StatelessWidget {
  Widget build(BuildContext ctx) => Column(children: [
    Text('Read now'),
    Text('Open news'),
    Text('Open news'),
  ]);
}
''';
    final source = write('lib/screen.dart', original);
    const catalogSource =
        '{ "settings": { "cta": "Read now", "openNews": "Existing" }, "header": {"title":"Headline"} }\n';
    final catalog = write('languages/en.json', catalogSource);
    final args = ['extract', '--section', 'settings'];

    final preview = await run(args);
    expect(preview.exitCode, 0, reason: '${preview.stderr}');
    final previewText = preview.stdout as String;
    expect(previewText, contains('settings.openNews2 = "Open news"'));
    expect(previewText, contains('AppLabels.text(ctx, "settings", "cta")'));
    expect(source.readAsStringSync(), original);
    expect(catalog.readAsStringSync(), catalogSource);
    final token = _token(preview);

    catalog.writeAsStringSync(catalogSource + '\n');
    final stale = await run([...args, '--apply', token]);
    expect(stale.exitCode, 2);
    expect(stale.stderr, contains('Preview token does not match'));
    expect(source.readAsStringSync(), original);

    catalog.writeAsStringSync(catalogSource);
    final applied = await run([...args, '--apply', token]);
    expect(applied.exitCode, 0, reason: '${applied.stderr}');
    final updated = source.readAsStringSync();
    expect(
      updated,
      contains('import "utils/app_labels.dart" as labelToolL10n;'),
    );
    expect(updated, contains('AppLabels.text(ctx, "settings", "cta")'));
    expect('openNews2'.allMatches(updated), hasLength(2));
    expect(jsonDecode(catalog.readAsStringSync()), {
      'settings': {
        'cta': 'Read now',
        'openNews': 'Existing',
        'openNews2': 'Open news',
      },
      'header': {'title': 'Headline'},
    });
    expect(
      catalog.readAsStringSync(),
      contains('"header": {"title":"Headline"}'),
    );
  });

  test('duplicate keys including escaped names prevent any edits', () async {
    write('lib/utils/app_labels.dart', 'abstract class AppLabels {}\n');
    final source = write(
      'lib/screen.dart',
      "Widget build(BuildContext ctx) => Text('Hello');\n",
    );
    const duplicate = r'{"settings":{"close":"One","cl\u006fse":"Two"}}';
    final catalog = write('languages/en.json', duplicate);
    final result = await run(['extract', '--section', 'settings']);
    expect(result.exitCode, 2);
    expect(result.stderr, contains('Duplicate catalog key'));
    expect(catalog.readAsStringSync(), duplicate);
    expect(source.readAsStringSync(), contains("Text('Hello')"));
  });

  test('ARB uses l10n.yaml, preserves metadata, and skips ICU text', () async {
    write('l10n.yaml', '''
arb-dir: lib/labels
template-arb-file: strings_en.arb
output-dir: lib/generated
output-localization-file: labels.dart
output-class: Labels
nullable-getter: false
required-resource-attributes: true
''');
    final catalog = write(
      'lib/labels/strings_en.arb',
      '{"@@locale":"en","existing":"Existing","@existing":{"description":"Keep me"}}\n',
    );
    final source = write('lib/screen.dart', '''
class Screen extends StatelessWidget {
  Widget build(BuildContext context) => Column(children: [
    Text('New label'),
    Text('Hello {name}'),
  ]);
}
''');
    final preview = await run(['extract']);
    expect(preview.exitCode, 0, reason: '${preview.stderr}');
    expect(preview.stdout, contains('Manual review:'));
    expect(preview.stdout, contains('newLabel = "New label"'));
    expect(preview.stdout, contains('generated/labels.dart'));
    expect(preview.stdout, contains('Labels.of(context).newLabel'));

    write('lib/utils/app_labels.dart', 'abstract class AppLabels {}\n');
    final ambiguous = await run(['extract']);
    expect(ambiguous.exitCode, 2);
    expect(ambiguous.stderr, contains('Choose --mode'));
    final applied = await run([
      'extract',
      '--mode',
      'arb',
      '--apply',
      _token(preview),
    ]);
    expect(applied.exitCode, 0, reason: '${applied.stderr}');
    expect(source.readAsStringSync(), contains("Text('Hello {name}')"));
    expect(jsonDecode(catalog.readAsStringSync()), {
      '@@locale': 'en',
      'existing': 'Existing',
      '@existing': {'description': 'Keep me'},
      'newLabel': 'New label',
      '@newLabel': {'description': 'UI label extracted from Dart source.'},
    });
  });
}

String _token(ProcessResult result) =>
    RegExp(r'--apply ([a-f0-9]{64})').firstMatch(result.stdout as String)![1]!;
