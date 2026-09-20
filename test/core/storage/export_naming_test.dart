import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/protocol/relative_path.dart';
import 'package:nearsend/core/storage/export_naming.dart';

/// Choosing a safe name to write the user's copy under.
///
/// Two properties carry the weight here. The derived path must be one this project would
/// accept, because it is handed to a platform adapter that writes to the user's storage;
/// and an existing entry must never be silently overwritten, because that is the one
/// mistake in this area the user cannot undo.
void main() {
  const ExportNamingPolicy policy = ExportNamingPolicy();

  ExportTargetPlan plan(
    String path, {
    Set<String> taken = const <String>{},
    ExportNamingPolicy with_ = policy,
  }) => with_.plan(frozenRelativePath: path, takenPaths: taken);

  group('no conflict', () {
    test('a free name is planned unchanged', () {
      final ExportTargetPlan result = plan('DCIM/photo.jpg');
      expect(result.status, ExportTargetStatus.planned);
      expect(result.safePath, 'DCIM/photo.jpg');
    });

    test('flatten drops the directories and keeps the last segment', () {
      final ExportTargetPlan result = plan(
        'a/b/c/report.pdf',
        with_: const ExportNamingPolicy(layout: ExportTargetLayout.flatten),
      );
      expect(result.safePath, 'report.pdf');
    });

    test('the frozen path is never rewritten when there is no conflict', () {
      const String frozen = 'docs/2026/notes.txt';
      expect(plan(frozen).safePath, frozen);
    });
  });

  group('conflicts', () {
    test('the default renames instead of asking or overwriting', () {
      final ExportTargetPlan result = plan(
        'photo.jpg',
        taken: <String>{'photo.jpg'},
      );
      expect(result.status, ExportTargetStatus.planned);
      expect(result.safePath, 'photo (1).jpg');
    });

    test('the suffix goes before the extension', () {
      expect(
        plan('archive.tar.gz', taken: <String>{'archive.tar.gz'}).safePath,
        'archive.tar (1).gz',
        reason: 'the last dot delimits the extension, as a filesystem sees it',
      );
    });

    test('a name with no extension is suffixed at the end', () {
      expect(plan('README', taken: <String>{'README'}).safePath, 'README (1)');
    });

    test('a leading-dot name keeps its dot', () {
      expect(
        plan('.gitignore', taken: <String>{'.gitignore'}).safePath,
        '.gitignore (1)',
        reason:
            'a leading dot is part of the name, not an extension, so the suffix must not '
            'produce ". (1)gitignore"',
      );
    });

    test('several taken variants are walked past', () {
      final ExportTargetPlan result = plan(
        'photo.jpg',
        taken: <String>{'photo.jpg', 'photo (1).jpg', 'photo (2).jpg'},
      );
      expect(result.safePath, 'photo (3).jpg');
    });

    test('a conflict inside a directory keeps the directory', () {
      final ExportTargetPlan result = plan(
        'DCIM/photo.jpg',
        taken: <String>{'DCIM/photo.jpg'},
      );
      expect(result.safePath, 'DCIM/photo (1).jpg');
    });

    test('ask reports the collision instead of guessing', () {
      final ExportTargetPlan result = plan(
        'photo.jpg',
        taken: <String>{'photo.jpg'},
        with_: const ExportNamingPolicy(conflict: NameConflictPolicy.ask),
      );
      expect(result.status, ExportTargetStatus.needsUserDecision);
      expect(result.conflictWith, 'photo.jpg');
      expect(result.safePath, isNull);
    });

    test('skip leaves the file out and says why', () {
      final ExportTargetPlan result = plan(
        'photo.jpg',
        taken: <String>{'photo.jpg'},
        with_: const ExportNamingPolicy(conflict: NameConflictPolicy.skip),
      );
      expect(result.status, ExportTargetStatus.skipped);
      expect(result.reason, contains('photo.jpg'));
      expect(result.safePath, isNull);
    });

    test('autoRename gives up rather than looping forever', () {
      final ExportTargetPlan result = plan(
        'photo.jpg',
        taken: <String>{'photo.jpg', 'photo (1).jpg', 'photo (2).jpg'},
        with_: const ExportNamingPolicy(maxRenameAttempts: 2),
      );
      expect(result.status, ExportTargetStatus.skipped);
      expect(result.reason, contains('2'));
    });

    test('each conflict policy has a distinct message key', () {
      final Set<String> keys = <String>{
        for (final NameConflictPolicy p in NameConflictPolicy.values)
          p.messageKey,
      };
      expect(keys.length, NameConflictPolicy.values.length);
    });
  });

  group('case', () {
    test('a differently-cased name counts as taken by default', () {
      final ExportTargetPlan result = plan(
        'Photo.JPG',
        taken: <String>{'photo.jpg'},
      );
      expect(
        result.status,
        ExportTargetStatus.planned,
        reason: 'the target may resolve both to one entry',
      );
      expect(
        result.safePath,
        'Photo (1).JPG',
        reason:
            'treating a case-insensitive target as case-sensitive risks overwriting a '
            'file the user already had; the other mistake only costs a suffix',
      );
    });

    test('a case-sensitive target can be opted into', () {
      final ExportTargetPlan result = plan(
        'Photo.JPG',
        taken: <String>{'photo.jpg'},
        with_: const ExportNamingPolicy(targetIsCaseInsensitive: false),
      );
      expect(result.safePath, 'Photo.JPG');
    });

    test('the planned name keeps the case it was given', () {
      expect(plan('Photo.JPG').safePath, 'Photo.JPG');
      expect(plan('photo.jpg').safePath, 'photo.jpg');
    });
  });

  group('length and safety', () {
    test('an over-long segment is shortened to fit', () {
      final String long = '${'a' * 300}.jpg';
      final ExportTargetPlan result = plan(
        long,
        with_: const ExportNamingPolicy(maxSegmentBytes: 200),
      );

      expect(result.status, ExportTargetStatus.planned);
      final String segment = result.safePath!.split('/').last;
      expect(utf8.encode(segment).length, lessThanOrEqualTo(200));
      expect(
        segment,
        endsWith('.jpg'),
        reason: 'the extension is what lets the user open the file',
      );
    });

    test('an over-long directory segment is shortened too', () {
      final ExportTargetPlan result = plan(
        '${'d' * 300}/file.txt',
        with_: const ExportNamingPolicy(maxSegmentBytes: 50),
      );

      expect(result.status, ExportTargetStatus.planned);
      for (final String segment in result.safePath!.split('/')) {
        expect(utf8.encode(segment).length, lessThanOrEqualTo(50));
      }
    });

    test('truncation never splits a rune', () {
      // Four-byte runes, so a cap that is not a multiple of four lands mid-character.
      final String emoji = '😀' * 100;
      final ExportTargetPlan result = plan(
        '$emoji.txt',
        with_: const ExportNamingPolicy(maxSegmentBytes: 41),
      );

      expect(result.status, ExportTargetStatus.planned);
      final String segment = result.safePath!.split('/').last;
      expect(utf8.encode(segment).length, lessThanOrEqualTo(41));
      expect(
        utf8.decode(utf8.encode(segment)),
        segment,
        reason:
            'a lone surrogate is not valid UTF-8 and would reach the filesystem as '
            'U+FFFD, a different name than the one returned',
      );
    });

    test('a stem truncated into a reserved device name is guarded', () {
      final ExportTargetPlan result = plan(
        'CONSOLE',
        with_: const ExportNamingPolicy(maxSegmentBytes: 3),
      );

      expect(result.safePath, '_CON');
      expect(
        RelativePathRules.isReservedName(result.safePath!.split('/').last),
        isFalse,
        reason:
            'on Windows CON resolves to a device, so the file would appear to save and '
            'then not exist',
      );
    });

    test('a trailing space left by truncation is trimmed, not abandoned', () {
      final ExportTargetPlan result = plan(
        'ab cdef',
        with_: const ExportNamingPolicy(maxSegmentBytes: 3),
      );

      expect(
        result.status,
        ExportTargetStatus.planned,
        reason:
            'the user\'s file has a legal name; losing it to a truncation artefact would '
            'be worse than a slightly shorter name',
      );
      expect(result.safePath, 'ab');
    });

    test('a trailing dot left by truncation is trimmed', () {
      final ExportTargetPlan result = plan(
        'ab.cdef',
        with_: const ExportNamingPolicy(maxSegmentBytes: 3),
      );
      expect(result.status, ExportTargetStatus.planned);
      expect(result.safePath, isNot(endsWith('.')));
    });

    test('a suffix still fits after shortening', () {
      const ExportNamingPolicy capped = ExportNamingPolicy(
        maxSegmentBytes: 200,
      );
      final String long = '${'a' * 300}.jpg';

      // What the target can actually hold is the shortened name, so that is what a
      // previous export of the same file would have left behind. A 300-byte segment
      // could never have been written there.
      final String alreadyThere = plan(long, with_: capped).safePath!;
      expect(utf8.encode(alreadyThere).length, lessThanOrEqualTo(200));

      final ExportTargetPlan result = plan(
        long,
        taken: <String>{alreadyThere},
        with_: capped,
      );

      expect(result.status, ExportTargetStatus.planned);
      final String segment = result.safePath!.split('/').last;
      expect(
        utf8.encode(segment).length,
        lessThanOrEqualTo(200),
        reason: 'adding the suffix must not push the segment back over the cap',
      );
      expect(segment, contains('(1)'));
      expect(segment, endsWith('.jpg'));
    });

    test('every planned path passes the protocol path rules', () {
      final List<String> inputs = <String>[
        'photo.jpg',
        'DCIM/photo.jpg',
        'a/b/c/report.pdf',
        '.gitignore',
        'README',
        'archive.tar.gz',
        '${'x' * 400}.txt',
        '照片/相册.jpg',
        '😀😀😀.png',
        'CONSOLE',
        'ab cdef',
      ];
      const List<ExportNamingPolicy> policies = <ExportNamingPolicy>[
        ExportNamingPolicy(),
        ExportNamingPolicy(layout: ExportTargetLayout.flatten),
        ExportNamingPolicy(maxSegmentBytes: 8),
        ExportNamingPolicy(maxSegmentBytes: 3),
      ];

      for (final String input in inputs) {
        for (final ExportNamingPolicy p in policies) {
          final ExportTargetPlan result = p.plan(
            frozenRelativePath: input,
            takenPaths: <String>{input},
          );
          if (!result.isPlanned) {
            continue;
          }
          expect(
            () => RelativePathRules.validate(result.safePath!),
            returnsNormally,
            reason:
                'policy $p produced "${result.safePath}" for "$input", which the project '
                'would not accept from a peer',
          );
        }
      }
    });
  });

  group('inputs the protocol already accepted', () {
    test('a valid frozen path is not rejected for being valid', () {
      for (final String path in <String>[
        'photo.jpg',
        'DCIM/100ANDRO/IMG_0001.jpg',
        '文档/报告 2026.pdf',
        'a.b.c',
      ]) {
        expect(
          RelativePathRules.validate(path),
          path,
          reason: 'the test inputs must be ones the protocol accepts',
        );
        expect(plan(path).status, ExportTargetStatus.planned);
      }
    });

    test('the policy does not change a name it has no reason to change', () {
      const String frozen = 'DCIM/photo.jpg';
      expect(plan(frozen).safePath, frozen);
      expect(plan(frozen).safePath, frozen);
    });
  });
}
