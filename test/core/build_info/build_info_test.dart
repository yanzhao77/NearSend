import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/build_info/build_info.dart';
import 'package:nearsend/core/storage/storage_schema.dart';

/// Guards the single-source-of-truth rules documented in
/// `lib/core/build_info/build_info.dart`.
///
/// The most important assertion here is the pubspec consistency check: it keeps
/// `pubspec.yaml` as the authority for the released version without pulling in a
/// third-party plugin (ADR-0001 decision 6).
void main() {
  group('build info', () {
    test(
      'pubspec version matches the declared app version and build number',
      () {
        final String pubspec = File('pubspec.yaml').readAsStringSync();
        final RegExpMatch? match = RegExp(
          r'^version:\s*(\S+)\s*$',
          multiLine: true,
        ).firstMatch(pubspec);

        expect(
          match,
          isNotNull,
          reason: 'pubspec.yaml must declare a top-level "version:" entry',
        );

        final List<String> parts = match!.group(1)!.split('+');
        expect(
          parts.first,
          kAppVersion,
          reason: 'kAppVersion must match pubspec.yaml version',
        );
        expect(
          parts.length,
          2,
          reason:
              'pubspec.yaml version must carry a build number, e.g. 0.1.0+1',
        );
        expect(
          parts[1],
          kAppBuildNumber,
          reason: 'kAppBuildNumber must match the pubspec.yaml build number',
        );
      },
    );

    test('protocol identity matches the v1.0-draft1 draft and is not frozen', () {
      expect(kProtocolMajor, 1);
      expect(kProtocolMinor, 0);
      expect(kProtocolDraftLabel, '1.0-draft1');
      expect(protocolVersionDisplay, '1.0');

      // docs/protocol/v1.0-draft1.md is explicitly not frozen: it still needs an
      // independent implementation compared against docs/protocol/vectors-v1.json.
      expect(
        kProtocolFrozen,
        isFalse,
        reason:
            'the protocol must not be reported as frozen before T02-01/T02-02',
      );
      expect(protocolStatusDisplay, contains('未冻结'));
    });

    test('schema display uses the storage schema authority', () {
      // Pinned on purpose: bumping the schema has to be a deliberate act, and the display must
      // never be a second definition of the number.
      expect(
        StorageSchema.currentVersion,
        7,
        reason: 'T12-03 adds the non-secret app_settings migration',
      );
      expect(
        dbSchemaDisplay,
        startsWith('${StorageSchema.currentVersion}'),
        reason:
            'the display consumes StorageSchema rather than repeating a number',
      );
      expect(dbSchemaDisplay, contains('存储层已实现'));
      expect(dbSchemaDisplay, contains('应用尚未装配'));
      expect(dbSchemaDisplay, isNot(contains('数据库尚未创建')));
    });

    test('the Git commit is never invented', () {
      if (!isGitShaInjected) {
        expect(gitShortSha, isNull);
        expect(gitShaDisplay, contains('unknown'));
      } else {
        expect(
          kGitSha,
          matches(RegExp(r'^[0-9a-f]{40}$')),
          reason: 'an injected NS_GIT_SHA must be a full lowercase commit id',
        );
        expect(gitShortSha, isNotNull);
        expect(gitShortSha!.length, lessThanOrEqualTo(kGitShortShaLength));
        expect(gitShaDisplay, startsWith(gitShortSha!));
      }
    });

    test(
      'build channel is either injected or explicitly reported as unknown',
      () {
        if (kBuildChannel.isEmpty) {
          expect(buildChannelDisplay, contains('unknown'));
        } else {
          expect(buildChannelDisplay, kBuildChannel);
        }
      },
    );
  });
}
