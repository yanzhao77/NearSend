/// The `/v1` success bodies, `docs/protocol/v1.0-draft1.md` §4, §7 and §9.
///
/// §7's table fixes a response for every endpoint, and §4 fixes how the numbers inside them
/// are written. Two of those rules shape this file.
///
/// ## Which numbers are strings and which are JSON numbers
///
/// §4 is explicit but easy to misread:
///
/// > 字节数、块编号、chunkCount、leaseEpoch、checkpointSeq：十进制字符串
/// > 协议版本、chunkSizeBytes、length、fileCount、pageLimit 使用 JSON 整数
///
/// So `committedBytes` and `leaseEpoch` travel as strings while `length` and `fileCount`
/// travel as numbers, and a response that swaps them is one a peer cannot read. Each model
/// here stores an `int` and does the conversion at the edge through
/// [encodeDecimalString] or [parseDecimalString], so the wire form is decided in one place
/// per field rather than by whatever a caller happened to pass.
///
/// ## Tokens appear in exactly two responses
///
/// §7: "成功体中的 token 字段只出现在专门授权/恢复响应，所有控制响应 Cache-Control: no-store".
/// [TokenBearingResponse] marks the two that may carry one, and a test asserts that no
/// other model implements it - so a token added to, say, the status body would have to be
/// a deliberate change to that set rather than an accident.
///
/// ## What is not here
///
/// §9's status body carries chunk ranges with their own validity rules, and §7's binary
/// chunk response is not a JSON body at all. Both are their own pieces of work, and neither
/// is claimed by this file.
library;

import 'package:nearsend/core/protocol/base64url.dart';
import 'package:nearsend/core/protocol/manifest_page.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/protocol_validation.dart';
import 'package:nearsend/core/protocol/transfer_state.dart';

/// A response that may carry a credential.
///
/// Deliberately an interface rather than a flag: §7 allows a token in the dedicated
/// authorisation and recovery responses and nowhere else, so "which models carry one" is
/// answerable by a test over the type rather than by reading each `toJson`.
abstract interface class TokenBearingResponse {
  /// The credential fields this response carries, for a diagnostics view that must not
  /// print them.
  Set<String> get credentialFields;
}

/// `{stored:true}` — §7's acknowledgement for the four write-and-confirm endpoints.
class StoredAck {
  const StoredAck();

  static const Set<String> _keys = <String>{'stored'};

  Map<String, Object?> toJson() => <String, Object?>{'stored': true};

  static StoredAck parse(Map<String, Object?> json) {
    rejectUnknownKeys(json, _keys, 'the stored acknowledgement');
    if (requireField(json, 'stored', 'the stored acknowledgement') != true) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'the stored acknowledgement must say stored: true',
      );
    }
    return const StoredAck();
  }
}

/// `{mirrored:true}` — §7's answer to a checkpoint report from a client receiver.
///
/// The name matters: §9 says the server "只更新显示镜像", so this acknowledges that the
/// figure was recorded for display and **not** that the server has verified the bytes.
class MirroredAck {
  const MirroredAck();

  static const Set<String> _keys = <String>{'mirrored'};

  Map<String, Object?> toJson() => <String, Object?>{'mirrored': true};

  static MirroredAck parse(Map<String, Object?> json) {
    rejectUnknownKeys(json, _keys, 'the mirrored acknowledgement');
    if (requireField(json, 'mirrored', 'the mirrored acknowledgement') !=
        true) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'the mirrored acknowledgement must say mirrored: true',
      );
    }
    return const MirroredAck();
  }
}

/// `{state}` — the body several endpoints answer with.
class StateResponse {
  const StateResponse(this.state);

  final TransferState state;

  static const Set<String> _keys = <String>{'state'};

  Map<String, Object?> toJson() => <String, Object?>{'state': state.wireName};

  static StateResponse parse(Map<String, Object?> json) {
    rejectUnknownKeys(json, _keys, 'the state response');
    return StateResponse(_readState(json['state']));
  }
}

/// `201 {transferId,state:STAGING}` — §7's answer to `POST /transfers`.
class TransferCreated {
  const TransferCreated({required this.transferId, required this.state});

  final String transferId;
  final TransferState state;

  static const Set<String> _keys = <String>{'transferId', 'state'};

  Map<String, Object?> toJson() => <String, Object?>{
    'transferId': transferId,
    'state': state.wireName,
  };

  static TransferCreated parse(Map<String, Object?> json) {
    rejectUnknownKeys(json, _keys, 'the created transfer');
    final Object? transferId = requireField(
      json,
      'transferId',
      'the created transfer',
    );
    uuidToBytes(transferId, 'transferId');
    return TransferCreated(
      transferId: transferId! as String,
      state: _readState(json['state']),
    );
  }
}

/// One entry of `GET /offers` (§7, §6).
class OfferSummary {
  const OfferSummary({
    required this.transferId,
    required this.manifestDigest,
    required this.fileCount,
    required this.totalBytes,
  });

  final String transferId;

  /// The digest the receiver must verify against §6's seal.
  final String manifestDigest;

  /// A JSON integer (§4).
  final int fileCount;

  /// A byte count, so a decimal string (§4).
  final int totalBytes;

  static const Set<String> _keys = <String>{
    'transferId',
    'manifestDigest',
    'fileCount',
    'totalBytes',
  };

  Map<String, Object?> toJson() => <String, Object?>{
    'transferId': transferId,
    'manifestDigest': manifestDigest,
    'fileCount': fileCount,
    'totalBytes': encodeDecimalString(totalBytes, 'totalBytes'),
  };

  static OfferSummary parse(Map<String, Object?> json) {
    rejectUnknownKeys(json, _keys, 'an offer');
    final Object? transferId = requireField(json, 'transferId', 'an offer');
    uuidToBytes(transferId, 'transferId');
    final Object? digest = requireField(json, 'manifestDigest', 'an offer');
    sha256HexToBytes(digest, 'manifestDigest');

    return OfferSummary(
      transferId: transferId! as String,
      manifestDigest: digest! as String,
      fileCount: parseJsonInteger(
        requireField(json, 'fileCount', 'an offer'),
        'fileCount',
      ),
      totalBytes: parseDecimalString(
        requireField(json, 'totalBytes', 'an offer'),
        'totalBytes',
      ),
    );
  }
}

/// `{offers:[...],nextCursor}` — §7's answer to `GET /offers`.
class OffersPage {
  const OffersPage({required this.offers, this.nextCursor});

  final List<OfferSummary> offers;

  /// The opaque value to pass back, or null at the end.
  ///
  /// §6 says an unknown session cannot enumerate offers at all, so an empty page is a
  /// legitimate answer to a session that has none rather than an error.
  final String? nextCursor;

  static const Set<String> _keys = <String>{'offers', 'nextCursor'};

  Map<String, Object?> toJson() => <String, Object?>{
    'offers': <Object?>[
      for (final OfferSummary offer in offers) offer.toJson(),
    ],
    'nextCursor': nextCursor,
  };

  static OffersPage parse(Map<String, Object?> json) {
    rejectUnknownKeys(json, _keys, 'the offers page');
    final Object? offers = requireField(json, 'offers', 'the offers page');
    if (offers is! List) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'offers must be an array',
      );
    }
    if (offers.length > ProtocolLimits.filePageLimit) {
      throw ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'an offers page carries at most ${ProtocolLimits.filePageLimit} entries, got '
        '${offers.length}',
      );
    }

    final List<OfferSummary> parsed = <OfferSummary>[];
    for (int i = 0; i < offers.length; i++) {
      final Object? entry = offers[i];
      if (entry is! Map) {
        throw ProtocolViolation(
          ProtocolErrorCode.invalidField,
          'offers[$i] must be an object',
        );
      }
      parsed.add(OfferSummary.parse(entry.cast<String, Object?>()));
    }

    final Object? cursor = json['nextCursor'];
    if (cursor != null && cursor is! String) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'nextCursor must be null or a string',
      );
    }
    if (cursor is String && cursor.isEmpty) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'nextCursor must not be an empty string; null means the end',
      );
    }

    return OffersPage(
      offers: List<OfferSummary>.unmodifiable(parsed),
      nextCursor: cursor as String?,
    );
  }
}

/// The per-chunk write outcome of §8.
enum ChunkWriteState {
  /// §8: "verified_pending 只证明本次块长度/摘要正确，不可释放持久化确认跟踪".
  verifiedPending('verified_pending'),

  /// The block is durably committed and is now part of the resumable checkpoint.
  committed('committed');

  const ChunkWriteState(this.wireValue);

  final String wireValue;

  static ChunkWriteState parse(Object? value) {
    for (final ChunkWriteState state in ChunkWriteState.values) {
      if (state.wireValue == value) {
        return state;
      }
    }
    throw const ProtocolViolation(
      ProtocolErrorCode.invalidField,
      'a chunk write state must be verified_pending or committed',
    );
  }
}

/// `{index,state,leaseEpoch,checkpointSeq}` — §8's answer to a chunk `PUT`.
class ChunkWriteResult {
  const ChunkWriteResult({
    required this.index,
    required this.state,
    required this.leaseEpoch,
    required this.checkpointSeq,
  });

  /// A chunk number, so a decimal string on the wire (§4).
  final int index;

  final ChunkWriteState state;

  /// A write generation, so a decimal string (§4).
  final int leaseEpoch;

  /// A checkpoint sequence, so a decimal string (§4).
  final int checkpointSeq;

  static const Set<String> _keys = <String>{
    'index',
    'state',
    'leaseEpoch',
    'checkpointSeq',
  };

  Map<String, Object?> toJson() => <String, Object?>{
    'index': encodeDecimalString(index, 'index'),
    'state': state.wireValue,
    'leaseEpoch': encodeDecimalString(leaseEpoch, 'leaseEpoch'),
    'checkpointSeq': encodeDecimalString(checkpointSeq, 'checkpointSeq'),
  };

  static ChunkWriteResult parse(Map<String, Object?> json) {
    rejectUnknownKeys(json, _keys, 'the chunk write result');
    return ChunkWriteResult(
      index: parseDecimalString(
        requireField(json, 'index', 'the chunk write result'),
        'index',
      ),
      state: ChunkWriteState.parse(
        requireField(json, 'state', 'the chunk write result'),
      ),
      leaseEpoch: parseDecimalString(
        requireField(json, 'leaseEpoch', 'the chunk write result'),
        'leaseEpoch',
      ),
      checkpointSeq: parseDecimalString(
        requireField(json, 'checkpointSeq', 'the chunk write result'),
        'checkpointSeq',
      ),
    );
  }
}

/// The `type` of a server-to-client control command (§7).
enum ControlCommandType {
  pause('pause'),
  cancel('cancel');

  const ControlCommandType(this.wireValue);

  final String wireValue;

  static ControlCommandType parse(Object? value) {
    for (final ControlCommandType type in ControlCommandType.values) {
      if (type.wireValue == value) {
        return type;
      }
    }
    throw const ProtocolViolation(
      ProtocolErrorCode.invalidField,
      'a control command type must be pause or cancel',
    );
  }
}

/// One `{seq,type}` entry of a control poll.
class ControlCommand {
  const ControlCommand({required this.seq, required this.type});

  /// A sequence number, so a decimal string (§4).
  final int seq;

  final ControlCommandType type;

  static const Set<String> _keys = <String>{'seq', 'type'};

  Map<String, Object?> toJson() => <String, Object?>{
    'seq': encodeDecimalString(seq, 'seq'),
    'type': type.wireValue,
  };

  static ControlCommand parse(Map<String, Object?> json) {
    rejectUnknownKeys(json, _keys, 'a control command');
    return ControlCommand(
      seq: parseDecimalString(
        requireField(json, 'seq', 'a control command'),
        'seq',
      ),
      type: ControlCommandType.parse(
        requireField(json, 'type', 'a control command'),
      ),
    );
  }
}

/// `{commands:[...],lastSeq}` — §7's answer to a control poll.
class ControlPoll {
  const ControlPoll({required this.commands, required this.lastSeq});

  final List<ControlCommand> commands;

  /// The highest sequence the server has issued, which is what the client acknowledges.
  final int lastSeq;

  static const Set<String> _keys = <String>{'commands', 'lastSeq'};

  Map<String, Object?> toJson() => <String, Object?>{
    'commands': <Object?>[
      for (final ControlCommand command in commands) command.toJson(),
    ],
    'lastSeq': encodeDecimalString(lastSeq, 'lastSeq'),
  };

  static ControlPoll parse(Map<String, Object?> json) {
    rejectUnknownKeys(json, _keys, 'the control poll');
    final Object? commands = requireField(json, 'commands', 'the control poll');
    if (commands is! List) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'commands must be an array',
      );
    }

    final List<ControlCommand> parsed = <ControlCommand>[];
    int previous = -1;
    for (int i = 0; i < commands.length; i++) {
      final Object? entry = commands[i];
      if (entry is! Map) {
        throw ProtocolViolation(
          ProtocolErrorCode.invalidField,
          'commands[$i] must be an object',
        );
      }
      final ControlCommand command = ControlCommand.parse(
        entry.cast<String, Object?>(),
      );
      if (command.seq <= previous) {
        throw const ProtocolViolation(
          ProtocolErrorCode.invalidField,
          'commands must be ascending by seq',
        );
      }
      previous = command.seq;
      parsed.add(command);
    }

    final int lastSeq = parseDecimalString(
      requireField(json, 'lastSeq', 'the control poll'),
      'lastSeq',
    );
    if (parsed.isNotEmpty && parsed.last.seq > lastSeq) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'lastSeq must not be smaller than the commands it describes',
      );
    }

    return ControlPoll(
      commands: List<ControlCommand>.unmodifiable(parsed),
      lastSeq: lastSeq,
    );
  }
}

/// `{taskResumeSecret,completionQuerySecret}` — §7's answer to the authorisation endpoint.
///
/// §2 keeps these in platform secure storage; this model exists so the wire form is
/// validated, and its `toString` deliberately does not render either value.
class AuthorizationGrant implements TokenBearingResponse {
  const AuthorizationGrant({
    required this.taskResumeSecret,
    required this.completionQuerySecret,
  });

  final String taskResumeSecret;
  final String completionQuerySecret;

  @override
  Set<String> get credentialFields => const <String>{
    'taskResumeSecret',
    'completionQuerySecret',
  };

  static const Set<String> _keys = <String>{
    'taskResumeSecret',
    'completionQuerySecret',
  };

  Map<String, Object?> toJson() => <String, Object?>{
    'taskResumeSecret': taskResumeSecret,
    'completionQuerySecret': completionQuerySecret,
  };

  static AuthorizationGrant parse(Map<String, Object?> json) {
    rejectUnknownKeys(json, _keys, 'the authorisation grant');
    return AuthorizationGrant(
      taskResumeSecret: _readSecret(json, 'taskResumeSecret'),
      completionQuerySecret: _readSecret(json, 'completionQuerySecret'),
    );
  }

  @override
  String toString() => 'AuthorizationGrant(two secrets, not rendered)';
}

/// §7's answer to `POST /transfers/{id}/resume`, which has two forms.
sealed class ResumeResponse {
  const ResumeResponse();

  /// 202 `{state:CHECKING_RESUME}`: the server is still working.
  ///
  /// §7 makes this a *state* rather than a wait, and §11 says a user confirmation must not
  /// occupy a long HTTP request. Repeating the same `requestId` while it is in flight is
  /// §9's defined behaviour, so a client backs off rather than starting a new resume.
  static const ResumeResponse checking = ResumeChecking();

  static ResumeResponse parse(
    Map<String, Object?> json, {
    required bool accepted,
  }) => accepted ? ResumeGranted.parse(json) : ResumeChecking.parse(json);
}

/// The 202 body: a state, and nothing else.
final class ResumeChecking extends ResumeResponse {
  const ResumeChecking();

  static const Set<String> _keys = <String>{'state'};

  Map<String, Object?> toJson() => <String, Object?>{
    'state': TransferState.checkingResume.wireName,
  };

  static ResumeChecking parse(Map<String, Object?> json) {
    rejectUnknownKeys(json, _keys, 'the resume acknowledgement');
    final TransferState? state = TransferState.fromWireName(
      requireField(json, 'state', 'the resume acknowledgement') as String? ??
          '',
    );
    if (state != TransferState.checkingResume) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'a 202 resume response must carry CHECKING_RESUME',
      );
    }
    return const ResumeChecking();
  }
}

/// The 200 body: the task access token and the generation it belongs to.
final class ResumeGranted extends ResumeResponse
    implements TokenBearingResponse {
  const ResumeGranted({
    required this.taskAccessToken,
    required this.leaseEpoch,
    required this.checkpointSeq,
    required this.state,
    this.expiresInSeconds = ProtocolLimits.sessionAccessTokenTtlSeconds,
  });

  final String taskAccessToken;

  /// A write generation, so a decimal string (§4).
  final int leaseEpoch;

  /// A checkpoint sequence, so a decimal string (§4).
  final int checkpointSeq;

  final TransferState state;

  final int expiresInSeconds;

  @override
  Set<String> get credentialFields => const <String>{'taskAccessToken'};

  static const Set<String> _keys = <String>{
    'taskAccessToken',
    'expiresInSeconds',
    'leaseEpoch',
    'checkpointSeq',
    'state',
  };

  Map<String, Object?> toJson() => <String, Object?>{
    'taskAccessToken': taskAccessToken,
    'expiresInSeconds': expiresInSeconds,
    'leaseEpoch': encodeDecimalString(leaseEpoch, 'leaseEpoch'),
    'checkpointSeq': encodeDecimalString(checkpointSeq, 'checkpointSeq'),
    'state': state.wireName,
  };

  static ResumeGranted parse(Map<String, Object?> json) {
    rejectUnknownKeys(json, _keys, 'the resume grant');
    final Object? token = requireField(
      json,
      'taskAccessToken',
      'the resume grant',
    );
    // §3 makes every access token 32 random bytes in the canonical unpadded form.
    decodeBase64UrlNoPaddingExact(
      token,
      'taskAccessToken',
      expectedBytes: ProtocolLimits.accessTokenBytes,
    );

    final TransferState? state = TransferState.fromWireName(
      requireField(json, 'state', 'the resume grant') as String? ?? '',
    );
    if (state == null) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'the resume grant carries a state §10 does not define',
      );
    }

    final int expiresInSeconds = parseJsonInteger(
      requireField(json, 'expiresInSeconds', 'the resume grant'),
      'expiresInSeconds',
    );
    if (expiresInSeconds <= 0) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'expiresInSeconds must be positive',
      );
    }

    return ResumeGranted(
      taskAccessToken: token! as String,
      leaseEpoch: parseDecimalString(
        requireField(json, 'leaseEpoch', 'the resume grant'),
        'leaseEpoch',
      ),
      checkpointSeq: parseDecimalString(
        requireField(json, 'checkpointSeq', 'the resume grant'),
        'checkpointSeq',
      ),
      state: state,
      expiresInSeconds: expiresInSeconds,
    );
  }

  @override
  String toString() =>
      'ResumeGranted(${state.wireName}, epoch $leaseEpoch, seq $checkpointSeq)';
}

/// Reads a §4 base64url secret of the protocol's token length.
String _readSecret(Map<String, Object?> json, String field) {
  final Object? value = requireField(json, field, 'the authorisation grant');
  decodeBase64UrlNoPaddingExact(
    value,
    field,
    expectedBytes: ProtocolLimits.accessTokenBytes,
  );
  return value! as String;
}

TransferState _readState(Object? value) {
  if (value is! String) {
    throw const ProtocolViolation(
      ProtocolErrorCode.invalidField,
      'state must be a string',
    );
  }
  final TransferState? state = TransferState.fromWireName(value);
  if (state == null) {
    throw ProtocolViolation(
      ProtocolErrorCode.invalidField,
      'the response carries a state §10 does not define',
    );
  }
  return state;
}

/// The four acknowledgement bodies §7 reuses across endpoints.
///
/// Exposed so a caller can tell "this endpoint answers with a state" from "it answers with
/// stored:true" without re-reading §7's table at each call site.
abstract final class ApiResponses {
  /// `{stored:true}`, used by the manifest page write, the authorisation receipt, the
  /// control receipt and the decision's stored form.
  static const StoredAck stored = StoredAck();

  /// `{mirrored:true}`, used only by the checkpoint endpoint.
  static const MirroredAck mirrored = MirroredAck();

  /// The one page shape §6 allows, reused by the two manifest reads.
  static const String pageKindFiles = 'files';
  static const String pageKindChunks = 'chunks';

  /// The `nextIndex` field §7's manifest page response adds to §6's page body.
  ///
  /// Held here rather than in [ManifestPage] because it is a property of the *response*,
  /// not of the page: §6 fixes what a page contains, §7 adds what comes after it.
  static const String nextIndexField = 'nextIndex';

  /// Reads `nextIndex` from a manifest page response body.
  ///
  /// Returns null at the end of the manifest, which is §7's "null 或十进制字符串".
  static int? nextIndex(Map<String, Object?> json, ManifestPage page) {
    final Object? value = json[nextIndexField];
    if (value == null) {
      return null;
    }
    final int next = parseDecimalString(value, nextIndexField);
    if (next != page.endIndex) {
      throw ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'nextIndex must be ${page.endIndex}, the index after this page, not $next',
      );
    }
    return next;
  }
}
