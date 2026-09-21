/// NearSend build and version identity.
///
/// This is the single source of truth for the identity values the application
/// must be able to report to the user: application version, Git commit,
/// protocol version and database schema version.
///
/// Authority and honesty rules:
///
/// * [kAppVersion] / [kAppBuildNumber] must stay consistent with `pubspec.yaml`.
///   `test/core/build_info/build_info_test.dart` enforces this, so the pubspec
///   stays the authority without a third-party plugin.
/// * The protocol version is owned by `docs/protocol/v1.0-draft1.md` and is
///   **not frozen**. Version negotiation and the canonical model belong to
///   T02-02. Nothing here may be presented to the user as a frozen protocol.
/// * The SQLite schema version comes only from [StorageSchema.currentVersion].
///   [kDatabaseRuntimeIntegrated] separately reports whether the application
///   startup path opens that schema; implementation and runtime wiring are not
///   the same claim.
/// * The Git commit is injected at build time through `--dart-define`
///   (`tooling/scripts/build.ps1`). When it is absent the value must be
///   reported as unknown rather than invented.
library;

import 'package:nearsend/core/storage/storage_schema.dart';

/// 产品显示名。
const String kAppName = 'NearSend';

/// 应用版本，必须与 `pubspec.yaml` 的 `version` 前半部分一致。
const String kAppVersion = '0.1.0';

/// 应用构建号，必须与 `pubspec.yaml` 的 `version` 中 `+` 之后的部分一致。
const String kAppBuildNumber = '1';

/// 协议主版本（`docs/protocol/v1.0-draft1.md` §3）。
const int kProtocolMajor = 1;

/// 协议次版本。
const int kProtocolMinor = 0;

/// 协议草案标识，用于区分同一主次版本下的不同草案。
const String kProtocolDraftLabel = '1.0-draft1';

/// 协议是否已冻结。在 T02-01/T02-02 通过独立实现与固定向量验证前必须为 false。
const bool kProtocolFrozen = false;

/// 应用启动路径是否已装配并打开接收方数据库。
///
/// schema 与迁移代码已经实现；这个值只描述产品运行时装配状态。
const bool kDatabaseRuntimeIntegrated = false;

/// 构建期注入的完整 Git 提交 SHA；未注入时为空字符串。
const String kGitSha = String.fromEnvironment('NS_GIT_SHA');

/// 构建期注入的工作区状态：`true` 表示构建时存在未提交改动。
const String kGitDirty = String.fromEnvironment('NS_GIT_DIRTY');

/// 构建期注入的构建渠道，例如 `local`、`ci`、`internal`、`release`。
const String kBuildChannel = String.fromEnvironment('NS_BUILD_CHANNEL');

/// 是否已注入 Git 提交。
bool get isGitShaInjected => kGitSha.isNotEmpty;

/// 构建时工作区是否存在未提交改动。
bool get isGitDirty => kGitDirty == 'true';

/// 供短 SHA 使用的长度。
const int kGitShortShaLength = 7;

/// 可安全展示的短 Git 提交，未注入时返回 `null`。
String? get gitShortSha => isGitShaInjected
    ? kGitSha.substring(
        0,
        kGitSha.length < kGitShortShaLength
            ? kGitSha.length
            : kGitShortShaLength,
      )
    : null;

/// 供 UI 展示的 Git 提交描述。
///
/// 绝不伪造提交：未注入时明确说明是未注入 SHA 的开发运行。
String get gitShaDisplay {
  final String? short = gitShortSha;
  if (short == null) {
    return 'unknown（未注入 NS_GIT_SHA 的开发运行）';
  }
  return isGitDirty ? '$short（构建时工作区有未提交改动）' : short;
}

/// 供 UI 展示的协议版本描述。
String get protocolVersionDisplay => '$kProtocolMajor.$kProtocolMinor';

/// 供 UI 展示的协议状态描述，明确标注草案未冻结。
String get protocolStatusDisplay =>
    kProtocolFrozen ? '已冻结' : '$kProtocolDraftLabel（草案，未冻结）';

/// 供 UI 展示的数据库 schema 描述。
String get dbSchemaDisplay => kDatabaseRuntimeIntegrated
    ? '${StorageSchema.currentVersion}'
    : '${StorageSchema.currentVersion}（存储层已实现，应用尚未装配）';

/// 供 UI 展示的构建渠道描述。
String get buildChannelDisplay =>
    kBuildChannel.isEmpty ? 'unknown（未注入 NS_BUILD_CHANNEL）' : kBuildChannel;
