import 'package:dev_tools_light/src/leaks/leak_trace.dart';

/// Matches a node (and its outgoing reference) of a [LeakTrace].
sealed class ReferencePattern {
  /// Const constructor for subclasses.
  const ReferencePattern();

  /// Whether [node] matches.
  bool matches(LeakTraceNode node);
}

/// Matches `className.fieldName` instance references.
final class InstanceFieldPattern extends ReferencePattern {
  /// Creates the pattern.
  const InstanceFieldPattern(this.className, this.fieldName);

  /// Matches [fieldName] on any class (for fields of mixins such as
  /// `SchedulerBinding`, whose concrete class varies).
  const InstanceFieldPattern.anyClass(this.fieldName) : className = null;

  /// The referencing class, or null for any class.
  final String? className;

  /// The referencing field.
  final String fieldName;

  @override
  bool matches(LeakTraceNode node) =>
      node.referenceKind == ReferenceKind.instanceField &&
      (className == null || node.className == className) &&
      node.referenceName == fieldName;
}

/// Matches a static field `ownerName.fieldName`.
final class StaticFieldPattern extends ReferencePattern {
  /// Creates the pattern.
  const StaticFieldPattern(this.ownerName, this.fieldName);

  /// The class or library that declares the field.
  final String ownerName;

  /// The field name.
  final String fieldName;

  @override
  bool matches(LeakTraceNode node) =>
      node.referenceKind == ReferenceKind.staticField &&
      node.className == ownerName &&
      node.referenceName == fieldName;
}

/// Matches any node of the given class (optionally in a given library).
final class ClassNamePattern extends ReferencePattern {
  /// Creates the pattern.
  const ClassNamePattern(this.className, {this.libraryUri});

  /// The class name.
  final String className;

  /// Optional library URI the class must live in.
  final String? libraryUri;

  @override
  bool matches(LeakTraceNode node) =>
      node.className == className &&
      (libraryUri == null || node.libraryUri == libraryUri);
}

/// Matches with a custom predicate.
final class CustomPattern extends ReferencePattern {
  /// Creates the pattern.
  const CustomPattern(this.test);

  /// The predicate.
  final bool Function(LeakTraceNode node) test;

  @override
  bool matches(LeakTraceNode node) => test(node);
}

/// A rule applied to every new leak trace.
sealed class ReferenceMatcher {
  /// Const constructor for subclasses.
  const ReferenceMatcher(this.pattern, this.description);

  /// What to look for.
  final ReferencePattern pattern;

  /// Why this rule exists (shown to the developer).
  final String description;

  /// Whether the rule applies to [trace].
  bool matches(LeakTrace trace) => trace.nodes.any(pattern.matches);
}

/// Traces matching this rule are dropped silently.
final class IgnoredReferenceMatcher extends ReferenceMatcher {
  /// Creates the matcher.
  const IgnoredReferenceMatcher(super.pattern, super.description);
}

/// Traces matching this rule are reported but flagged as a known library
/// leak (LeakCanary's "Library leaks").
final class LibraryLeakReferenceMatcher extends ReferenceMatcher {
  /// Creates the matcher.
  const LibraryLeakReferenceMatcher(super.pattern, super.description);
}

/// The built-in rules.
const List<ReferenceMatcher> defaultReferenceMatchers = [
  LibraryLeakReferenceMatcher(
    ClassNamePattern('WidgetInspectorService'),
    'The Flutter widget inspector (DevTools) keeps inspected and selected '
    'objects alive in debug mode.',
  ),
  LibraryLeakReferenceMatcher(
    ClassNamePattern('InspectorSelection'),
    'The widget inspector selection keeps the selected element and render '
    'object alive.',
  ),
  IgnoredReferenceMatcher(
    InstanceFieldPattern.anyClass('_postFrameCallbacks'),
    'Held by a pending post-frame callback: the framework releases routes, '
    'overlay entries and controllers after the next frame renders.',
  ),
];
