import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';

const _positionalText = {'Text', 'CustomeText', 'TextSpan', 'Text.rich'};
const _namedText = {
  'Text': {'semanticsLabel'},
  'Text.rich': {'semanticsLabel'},
  'TextSpan': {'text', 'semanticsLabel'},
  'Tooltip': {'message'},
  'InputDecoration': {
    'labelText',
    'hintText',
    'helperText',
    'errorText',
    'prefixText',
    'suffixText',
    'counterText',
    'semanticCounterText',
  },
  'IconButton': {'tooltip'},
  'IconButton.filled': {'tooltip'},
  'IconButton.filledTonal': {'tooltip'},
  'IconButton.outlined': {'tooltip'},
  'FloatingActionButton': {'tooltip'},
  'FloatingActionButton.extended': {'tooltip'},
  'Semantics': {'label', 'hint', 'value', 'onTapHint', 'onLongPressHint'},
  'CircularProgressIndicator': {'semanticsLabel'},
  'LinearProgressIndicator': {'semanticsLabel'},
  'Image.asset': {'semanticLabel'},
  'Image.network': {'semanticLabel'},
  'Image.file': {'semanticLabel'},
  'Image.memory': {'semanticLabel'},
  'CustomScaffold': {'title'},
  'AppSearchBar': {'hintText', 'clearLabel'},
  'CustomeTextField': {
    'label',
    'hint',
    'showPasswordLabel',
    'hidePasswordLabel',
  },
  'CustomSnackbar.show': {'message'},
  'SkeletonLoader': {'semanticsLabel'},
  'showDatePicker': {
    'helpText',
    'cancelText',
    'confirmText',
    'fieldHintText',
    'fieldLabelText',
    'errorFormatText',
    'errorInvalidText',
  },
};

final class Finding {
  const Finding(
    this.path,
    this.line,
    this.column,
    this.literal,
    this.site,
    this.context,
    this.reason,
  );

  final String path;
  final int line;
  final int column;
  final StringLiteral literal;
  final String site;
  final String? context;
  final String? reason;

  String get location => '$path:$line:$column';
  String? get value => literal.stringValue;
}

List<Finding> scanSource(String path, String source) {
  final result = parseString(
    content: source,
    path: path,
    throwIfDiagnostics: false,
  );
  if (result.errors.isNotEmpty) {
    final location = result.lineInfo.getLocation(result.errors.first.offset);
    throw FormatException(
      '$path:${location.lineNumber}:${location.columnNumber}: ${result.errors.first.message}',
    );
  }
  final visitor = _StringVisitor(
    path,
    result.unit,
    result.lineInfo.getLocation,
  );
  result.unit.accept(visitor);
  return visitor.findings;
}

final class _StringVisitor extends RecursiveAstVisitor<void> {
  _StringVisitor(this.path, this.unit, this.locate);

  final String path;
  final CompilationUnit unit;
  final CharacterLocation Function(int) locate;
  final findings = <Finding>[];

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    _inspect(node.constructorName.toSource(), node.argumentList);
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final target = node.target;
    if (!node.isCascaded &&
        !node.isNullAware &&
        (target == null || target is SimpleIdentifier)) {
      final name = node.methodName.name;
      _inspect(
        target == null ? name : '${target.toSource()}.$name',
        node.argumentList,
      );
    }
    super.visitMethodInvocation(node);
  }

  void _inspect(String call, ArgumentList arguments) {
    final named = _namedText[call];
    final positional = _positionalText.contains(call);
    if (named == null && !positional) return;
    for (final (index, argument) in arguments.arguments.indexed) {
      if (argument is NamedExpression) {
        final name = argument.name.label.name;
        if (named?.contains(name) ?? false) {
          _inspectValue(argument.expression, '$call.$name');
        }
      } else if (index == 0 && positional) {
        _inspectValue(argument, call);
      }
    }
  }

  void _inspectValue(Expression expression, String site) {
    switch (expression) {
      case StringLiteral():
        final value = expression.stringValue;
        if (!RegExp(
          r'\p{L}',
          unicode: true,
        ).hasMatch(_literalText(expression))) {
          return;
        }
        final location = locate(expression.offset);
        final context = _findContext(expression);
        final reason = switch (expression) {
          _ when value == null => 'interpolated message',
          _ when expression.inConstantContext => 'const expression',
          _
              when unit.directives.any(
                (directive) => directive is PartOfDirective,
              ) =>
            'part file',
          _ when context == null =>
            'no unshadowed BuildContext parameter in a synchronous build method or builder',
          _ => null,
        };
        findings.add(
          Finding(
            path,
            location.lineNumber,
            location.columnNumber,
            expression,
            site,
            context,
            reason,
          ),
        );
      case ParenthesizedExpression(:final expression):
        _inspectValue(expression, site);
      case ConditionalExpression(:final thenExpression, :final elseExpression):
        _inspectValue(thenExpression, site);
        _inspectValue(elseExpression, site);
      case BinaryExpression(
            :final leftOperand,
            :final rightOperand,
            :final operator,
          )
          when operator.lexeme == '??':
        _inspectValue(leftOperand, site);
        _inspectValue(rightOperand, site);
      default:
        break;
    }
  }
}

String _literalText(StringLiteral expression) => switch (expression) {
  StringInterpolation(:final elements) =>
    elements.whereType<InterpolationString>().map((part) => part.value).join(),
  AdjacentStrings(:final strings) => strings.map(_literalText).join(),
  _ => expression.stringValue ?? '',
};

String? _findContext(AstNode node) {
  for (
    var ancestor = node.parent;
    ancestor != null;
    ancestor = ancestor.parent
  ) {
    if (ancestor is! MethodDeclaration && ancestor is! FunctionExpression) {
      continue;
    }
    final body = switch (ancestor) {
      MethodDeclaration(:final body, name: final name)
          when name.lexeme == 'build' =>
        body,
      FunctionExpression(:final body, parent: NamedExpression(:final name))
          when name.label.name == 'builder' =>
        body,
      _ => null,
    };
    if (body == null || body.isAsynchronous || body.isGenerator) return null;
    final parameters = switch (ancestor) {
      MethodDeclaration(:final parameters) => parameters,
      FunctionExpression(:final parameters) => parameters,
      _ => null,
    };
    if (parameters == null) continue;
    for (final parameter in parameters.parameters) {
      if (parameter is! SimpleFormalParameter ||
          parameter.type?.toSource() != 'BuildContext')
        continue;
      final name = parameter.name?.lexeme;
      if (name == null) continue;
      final finder = _ShadowingVisitor(name);
      ancestor.accept(finder);
      if (!finder.found) return name;
    }
    return null;
  }
  return null;
}

final class _ShadowingVisitor extends RecursiveAstVisitor<void> {
  _ShadowingVisitor(this.name);
  final String name;
  bool found = false;

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    if (node.name.lexeme == name) found = true;
    super.visitVariableDeclaration(node);
  }

  @override
  void visitDeclaredVariablePattern(DeclaredVariablePattern node) {
    if (node.name.lexeme == name) found = true;
    super.visitDeclaredVariablePattern(node);
  }

  @override
  void visitDeclaredIdentifier(DeclaredIdentifier node) {
    if (node.name.lexeme == name) found = true;
    super.visitDeclaredIdentifier(node);
  }

  @override
  void visitCatchClauseParameter(CatchClauseParameter node) {
    if (node.name.lexeme == name) found = true;
    super.visitCatchClauseParameter(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    if (node.name.lexeme == name) found = true;
    super.visitFunctionDeclaration(node);
  }
}
