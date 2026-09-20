/// Choosing a safe name to write the user's copy under.
///
/// ## This is not the same job as validating `relativePath`
///
/// [RelativePathRules.validate] decides whether a path that *arrived* from a peer may be
/// accepted, and it deliberately returns the path unchanged because that exact string
/// participates in the manifest digest. This file does the other job: given an accepted
/// path, produce a name to write under at the user's chosen target, resolving collisions
/// with what is already there.
///
/// The distinction is why renaming is allowed here and forbidden there. `UI_UX_SPEC.md`
/// §4 requires a conflict policy ("询问/自动重命名/跳过；MVP 默认自动安全重命名"), and a
/// rename must never touch the frozen manifest - it changes where the copy lands, not what
/// the sender signed. The export record keeps the frozen path as it is and stores the
/// target it actually used.
///
/// ## Conservative by default
///
/// The default is to treat the target as **case-insensitive**. Windows, macOS and the
/// exFAT cards commonly used on Android all resolve `Photo.JPG` and `photo.jpg` to the
/// same entry. Treating a case-sensitive target as case-insensitive costs a needless
/// `(1)` suffix; getting it the other way round overwrites a file the user already had.
/// Only one of those two mistakes is recoverable.
library;

import 'dart:convert';

import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/relative_path.dart';

/// What to do when the name is already taken at the target.
enum NameConflictPolicy {
  /// Stop and let the user choose. Never guesses on the user's behalf.
  ask('export.conflict.ask'),

  /// Pick the next free `name (n)` variant. The MVP default, per `UI_UX_SPEC.md` §4.
  autoRename('export.conflict.autoRename'),

  /// Leave this file out. The rest of the queue continues, so the task may end
  /// partially completed rather than failing.
  skip('export.conflict.skip');

  const NameConflictPolicy(this.messageKey);

  final String messageKey;
}

/// How the frozen layout maps onto the target.
enum ExportTargetLayout {
  /// Keep the directories the sender had, so a transferred folder stays a folder.
  preserveStructure,

  /// Write every file directly into the target container, using only its last segment.
  flatten,
}

/// What the policy decided for one file.
enum ExportTargetStatus {
  /// A free, safe name was produced.
  planned,

  /// A conflict needs the user's decision and the policy is [NameConflictPolicy.ask].
  needsUserDecision,

  /// This file cannot be placed: the policy is to skip, every rename variant is taken,
  /// or the name could not be made safe.
  skipped,
}

/// The outcome of naming one file.
class ExportTargetPlan {
  const ExportTargetPlan._({
    required this.status,
    this.safePath,
    this.conflictWith,
    this.reason,
  });

  const ExportTargetPlan.planned(String safePath)
    : this._(status: ExportTargetStatus.planned, safePath: safePath);

  const ExportTargetPlan.needsUserDecision(String conflictWith)
    : this._(
        status: ExportTargetStatus.needsUserDecision,
        conflictWith: conflictWith,
      );

  const ExportTargetPlan.skipped(String reason)
    : this._(status: ExportTargetStatus.skipped, reason: reason);

  final ExportTargetStatus status;

  /// The relative path to write under, relative to the user's target. Null unless
  /// [status] is [ExportTargetStatus.planned].
  final String? safePath;

  /// The existing entry that collided. Set only for
  /// [ExportTargetStatus.needsUserDecision].
  final String? conflictWith;

  /// Why the file was skipped. Set only for [ExportTargetStatus.skipped].
  final String? reason;

  bool get isPlanned => status == ExportTargetStatus.planned;

  @override
  String toString() =>
      'ExportTargetPlan(${status.name}'
      '${safePath == null ? '' : ', $safePath'}'
      '${conflictWith == null ? '' : ', conflicts with $conflictWith'}'
      '${reason == null ? '' : ', $reason'})';
}

/// Derives a safe, free target path for one file.
class ExportNamingPolicy {
  const ExportNamingPolicy({
    this.conflict = NameConflictPolicy.autoRename,
    this.layout = ExportTargetLayout.preserveStructure,
    this.maxSegmentBytes = defaultMaxSegmentBytes,
    this.fallbackStem = defaultFallbackStem,
    this.maxRenameAttempts = defaultMaxRenameAttempts,
    this.targetIsCaseInsensitive = true,
  });

  final NameConflictPolicy conflict;
  final ExportTargetLayout layout;

  /// Cap on one path segment, in UTF-8 bytes.
  ///
  /// Well below the protocol's limit for the whole path: a target filesystem may impose
  /// 255 bytes per segment, and the suffix this policy adds must still fit.
  final int maxSegmentBytes;

  /// Used when a name cannot be made safe at all, so the file is still delivered.
  final String fallbackStem;

  /// How many `(n)` variants to try before giving up.
  final int maxRenameAttempts;

  /// Whether names that differ only by case are treated as the same entry.
  final bool targetIsCaseInsensitive;

  static const int defaultMaxSegmentBytes = 200;
  static const String defaultFallbackStem = 'received-file';
  static const int defaultMaxRenameAttempts = 1000;

  /// Decides where one file's copy goes.
  ///
  /// [frozenRelativePath] must already have passed [RelativePathRules.validate]; this
  /// method does not re-accept unfrozen input, but it does re-check its own output,
  /// because derivation can produce a name the original rules would not have allowed
  /// (truncation can turn a long stem into a reserved device name).
  ///
  /// [takenPaths] holds the entries already present at the target, as relative paths
  /// using `/` separators. Anything the platform cannot enumerate must be reported here
  /// or the copy may overwrite it.
  ExportTargetPlan plan({
    required String frozenRelativePath,
    required Set<String> takenPaths,
  }) {
    final Set<String> taken = targetIsCaseInsensitive
        ? <String>{for (final String p in takenPaths) p.toLowerCase()}
        : takenPaths;
    bool isTaken(String path) =>
        taken.contains(targetIsCaseInsensitive ? path.toLowerCase() : path);

    final String? candidate = _capPath(_layoutPath(frozenRelativePath));
    if (candidate == null) {
      return const ExportTargetPlan.skipped(
        'the name could not be shortened to a safe length',
      );
    }

    if (!isTaken(candidate)) {
      return ExportTargetPlan.planned(candidate);
    }

    switch (conflict) {
      case NameConflictPolicy.ask:
        return ExportTargetPlan.needsUserDecision(candidate);
      case NameConflictPolicy.skip:
        return ExportTargetPlan.skipped(
          'an entry named "$candidate" is already at the target',
        );
      case NameConflictPolicy.autoRename:
        for (int n = 1; n <= maxRenameAttempts; n++) {
          final String? variant = _withSuffix(candidate, n);
          if (variant == null) {
            break;
          }
          if (!isTaken(variant)) {
            return ExportTargetPlan.planned(variant);
          }
        }
        return ExportTargetPlan.skipped(
          'every "$candidate (n)" variant up to $maxRenameAttempts is taken',
        );
    }
  }

  /// Applies the layout, then re-checks the result is a path this project would accept.
  String _layoutPath(String frozenRelativePath) {
    final String mapped = switch (layout) {
      ExportTargetLayout.preserveStructure => frozenRelativePath,
      ExportTargetLayout.flatten => frozenRelativePath.substring(
        frozenRelativePath.lastIndexOf('/') + 1,
      ),
    };
    return mapped;
  }

  /// Shortens any over-long segment, and refuses a path it cannot make safe.
  String? _capPath(String path) {
    final List<String> segments = <String>[];
    for (final String segment in path.split('/')) {
      segments.add(_capSegment(segment, suffix: ''));
    }
    final String result = segments.join('/');
    return _isAcceptable(result) ? result : null;
  }

  /// The `n`-th rename variant, or null when it cannot be made safe.
  String? _withSuffix(String path, int n) {
    final int slash = path.lastIndexOf('/');
    final String parent = slash == -1 ? '' : path.substring(0, slash + 1);
    final String segment = slash == -1 ? path : path.substring(slash + 1);
    final String result = '$parent${_capSegment(segment, suffix: ' ($n)')}';
    return _isAcceptable(result) ? result : null;
  }

  /// Fits one segment into [maxSegmentBytes], placing [suffix] before the extension.
  ///
  /// Truncation walks runes rather than code units: cutting inside a surrogate pair would
  /// leave a lone surrogate, which is not valid UTF-8 and would be replaced by U+FFFD on
  /// the way to the filesystem - a different name than the one this method returned.
  String _capSegment(String segment, {required String suffix}) {
    final (String stem, String ext) = _splitExtension(segment);
    final int suffixBytes = utf8.encode(suffix).length;
    final int extBytes = utf8.encode(ext).length;

    // At least one byte for the stem, so an absurdly small cap still yields a name rather
    // than losing the file.
    final int stemBudget = maxSegmentBytes - extBytes - suffixBytes;
    String fittedStem = stem;
    if (utf8.encode(stem).length > stemBudget) {
      fittedStem = _truncateToBytes(stem, stemBudget);
    }

    // A truncated stem can end in a space or a dot, which a path segment may not do. Trim
    // rather than give up: the user's file has a legal name, and losing it to a truncation
    // artefact would be a worse outcome than a slightly shorter name.
    fittedStem = _trimTrailingSpaceOrDot(fittedStem);

    if (fittedStem.isEmpty) {
      final int fallbackBudget = stemBudget < 1 ? 1 : stemBudget;
      fittedStem = _trimTrailingSpaceOrDot(
        _truncateToBytes(fallbackStem, fallbackBudget),
      );
    }
    if (fittedStem.isEmpty) {
      // Even the fallback stem does not fit; one byte of it is still a usable name.
      fittedStem = _truncateToBytes(fallbackStem, 1);
    }

    // Truncation can land on a reserved device name, and a suffix does not rescue a
    // reserved stem because the check ignores the extension.
    final String guarded = RelativePathRules.isReservedName('$fittedStem$ext')
        ? '_$fittedStem'
        : fittedStem;

    return '$guarded$suffix$ext';
  }

  static String _trimTrailingSpaceOrDot(String value) {
    int end = value.length;
    while (end > 0) {
      final int unit = value.codeUnitAt(end - 1);
      if (unit == 0x20 || unit == 0x2E) {
        end--;
      } else {
        break;
      }
    }
    return value.substring(0, end);
  }

  /// Whether the derived path would satisfy the same lexical rules as an arrived one.
  ///
  /// Reusing the protocol rule rather than reimplementing it means "safe path" has one
  /// definition. A failure here is a bug in this policy, so it is reported as a skip -
  /// the file is not delivered, but nothing unsafe is written.
  bool _isAcceptable(String path) {
    try {
      RelativePathRules.validate(path);
      return true;
    } on ProtocolViolation {
      return false;
    }
  }

  /// Splits `name.ext` into stem and extension.
  ///
  /// A leading dot is part of the name, not an extension, so `.gitignore` has no
  /// extension and becomes `.gitignore (1)` rather than `. (1)gitignore`.
  static (String, String) _splitExtension(String segment) {
    final int dot = segment.lastIndexOf('.');
    if (dot <= 0) {
      return (segment, '');
    }
    return (segment.substring(0, dot), segment.substring(dot));
  }

  /// Truncates [value] to at most [maxBytes] UTF-8 bytes, never splitting a rune.
  static String _truncateToBytes(String value, int maxBytes) {
    if (maxBytes <= 0) {
      return '';
    }
    if (utf8.encode(value).length <= maxBytes) {
      return value;
    }
    int used = 0;
    int end = 0;
    for (final int rune in value.runes) {
      final int runeBytes = _utf8BytesForRune(rune);
      if (used + runeBytes > maxBytes) {
        break;
      }
      used += runeBytes;
      end += rune > 0xFFFF ? 2 : 1;
    }
    return value.substring(0, end);
  }

  static int _utf8BytesForRune(int rune) {
    if (rune <= 0x7F) {
      return 1;
    }
    if (rune <= 0x7FF) {
      return 2;
    }
    if (rune <= 0xFFFF) {
      return 3;
    }
    return 4;
  }
}
