# Flutter Label Tool

Scan Flutter source for hardcoded UI copy and migrate selected strings to your English catalog. This standalone Dart package requires Dart 3.11 or later.

## Install

Install from GitHub using Dart:

```sh
dart pub global activate --source git https://github.com/InfinitieParasgiri/flutter_label_tool.git
```

For a local clone, use `dart pub global activate --source path /path/to/flutter_label_tool`.
If your shell cannot find `label`, add Dart's pub cache bin directory to your PATH.
On macOS and Linux, add this line to your shell configuration:

```sh
export PATH="${PUB_CACHE:-$HOME/.pub-cache}/bin:$PATH"
```

If you previously defined a `label` alias, remove it from your shell configuration and open a new terminal to use the installed executable.

Run from your Flutter project root:

```sh
label scan
label extract
```

`scan` reports the file, line, column, and widget argument. It recognizes common cases such as `Text`, `TextSpan`, tooltips, form hints, accessibility labels, and News United's `CustomeText` and `CustomSnackbar.show`. Use `scan --json` for machine-readable output or `scan --check` to exit with code 1 when findings exist. Invalid input or CLI usage exits with code 2. Repeat `--source` before the command to limit the scan to files or directories. It defaults to `lib`.

```sh
label --source lib/screens/settings.dart scan
```

## Extract to AppLabels

The tool defaults to `languages/en.json` and `lib/utils/app_labels.dart` in this app. Copy the actual location from `scan` into `--at`. The following location is an example.

```sh
label extract \
  --at lib/screens/settings.dart:42:18 --section settings --key privacyTitle
```

The preview shows the catalog additions, exact source replacements, new imports, and any manual-review findings. Inspect it, then rerun the same command with `--apply PREVIEW_TOKEN` using the token it prints. A change to any file in the proposed edit invalidates the token. Review the resulting diff and run `flutter analyze` for the target app.

Omit `--key` to reuse an exact English match in the selected section or derive a key from the message. If several matches exist, select the intended key with `--key`. A new automatic key gets a numeric suffix when the base key is taken. An explicit key with a different existing value is an error. The tool checks for duplicate JSON keys before planning and inserts additions without rewriting existing values. The backend can override the resulting labels by returning the same section and key.

Omit `--at` to preview all supported edits within the source selection. Review that scope before applying. The default AppLabels section is `common`.

## Extract to Flutter gen-l10n

Set up the target Flutter project's localization delegates and supported locales first. The tool reads `l10n.yaml` for the ARB directory, template filename, output directory, generated filename, and generated class name. Its defaults are `lib/l10n/app_en.arb` and `lib/l10n/app_localizations.dart`. The English template must already exist.

```sh
label --root /path/to/flutter_app extract \
  --mode arb --at lib/screens/settings.dart:42:18 --key privacyTitle
```

Apply with the preview token, then run `flutter gen-l10n` from the target Flutter project. The tool edits the source and English template. Generated files and additional translations are handled by your existing localization workflow. See the [Flutter localization guide](https://docs.flutter.dev/ui/internationalization).

If a project enables both systems, pass `--mode app-labels` or `--mode arb` to select the destination for that extraction. Use `--catalog` or `--import` to override project-relative paths. Give each message a destination based on whether it needs backend overrides or ships with the app.

## Extraction limits

The scanner reads Dart syntax and matches known call names. It cannot determine whether code is reachable or trace every string through constants, variables, repositories, or custom widgets. Dynamically composed strings with literal words are reported for manual review. Numbers, punctuation, and interpolations containing only data expressions are skipped.

Automatic edits are limited to non-constant, plain strings in synchronous build methods or builders with an explicit, unshadowed `BuildContext` parameter. Review `const` widgets, ARB messages with ICU syntax, and other findings manually. Use `flutter analyze` to verify the chosen lookup and context after applying.

## Develop the tool

From this package directory, run `dart analyze` and `dart test`.
