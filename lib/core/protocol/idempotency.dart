/// `request_id` idempotency and `lease_epoch` arbitration, `docs/protocol/v1.0-draft1.md`
/// §8 and §9.
///
/// These two rules are what make recovery safe, and both are easy to get subtly wrong:
///
/// * a retried request must produce the **same** semantic result, not a second effect;
/// * the same recovery request id must never advance the write generation twice, because
///   that would silently invalidate in-flight writes from the previous generation;
/// * a client holding a superseded generation must be refused rather than allowed to
///   write into a resumed task (`STALE_LEASE`).
///
/// §8 also fixes the ordering a receiver must follow before a generation changes: revoke
/// the old session, wait for its writes to stop, then allocate the new epoch. A new epoch
/// handed out while old writes are still running is exactly the bug `lease_epoch` exists
/// to prevent, so allocation is modelled as an explicit, separate step rather than
/// something a caller can do implicitly.
///
/// ## Scope of this file
///
/// Rules and an in-memory store. Durable storage of idempotency records and generations
/// is T04-01's job; nothing here touches SQLite, the network or credentials.
library;

import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_validation.dart';

/// An operation that carries a `request_id` (§7).
enum ProtocolOperation {
  createTransfer,

  /// `PUT /transfers/{id}/manifest` — one manifest page.
  uploadManifestPage,

  seal,
  decision,
  authorizationReceipt,
  resume,
  checkpoint,
  pause,
  complete,
  cancel,
  controlReceipt,
}

/// The scope a `request_id` is unique within.
///
/// §9: "作用域是同一任务＋操作＋当前恢复凭证". The credential itself is a secret and must
/// never be held here, so the scope carries an opaque **fingerprint** produced by the
/// security layer. Two resumes separated by a re-pairing therefore have different scopes,
/// which is the intent: a request id from the old credential must not silently match a
/// request made under a new one.
class RequestScope {
  const RequestScope({
    required this.transferId,
    required this.operation,
    required this.credentialFingerprint,
  });

  final String transferId;
  final ProtocolOperation operation;

  /// Opaque, non-reversible identifier of the credential in force.
  ///
  /// Never the credential: `AGENTS.md` §5 keeps recovery secrets out of ordinary
  /// storage, logs and diagnostics.
  final String credentialFingerprint;

  @override
  bool operator ==(Object other) =>
      other is RequestScope &&
      other.transferId == transferId &&
      other.operation == operation &&
      other.credentialFingerprint == credentialFingerprint;

  @override
  int get hashCode => Object.hash(transferId, operation, credentialFingerprint);

  @override
  String toString() =>
      'RequestScope($transferId, ${operation.name}, credential#${credentialFingerprint.hashCode.toRadixString(16)})';
}

/// A write generation for one task (§8).
///
/// Zero means no generation has been allocated yet, so no writer may write.
class LeaseEpoch implements Comparable<LeaseEpoch> {
  const LeaseEpoch(this.value);

  /// Before the first `resume`.
  static const LeaseEpoch none = LeaseEpoch(0);

  final int value;

  LeaseEpoch next() => LeaseEpoch(value + 1);

  bool get isAllocated => value > 0;

  @override
  int compareTo(LeaseEpoch other) => value.compareTo(other.value);

  bool operator >(LeaseEpoch other) => value > other.value;
  bool operator <(LeaseEpoch other) => value < other.value;

  @override
  bool operator ==(Object other) => other is LeaseEpoch && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'LeaseEpoch($value)';
}

/// Tracks the single active write generation of one task.
class LeaseGuard {
  LeaseGuard({LeaseEpoch initial = LeaseEpoch.none}) : _current = initial;

  LeaseEpoch _current;

  /// The generation a writer must present.
  LeaseEpoch get current => _current;

  /// Revokes the current generation and allocates the next one.
  ///
  /// §8 requires the caller to have already revoked the old session and waited for its
  /// writes to stop; this method cannot verify that, which is why it is named for the
  /// whole action and documented. Returns the new generation.
  LeaseEpoch revokeAndAdvance() {
    _current = _current.next();
    return _current;
  }

  /// Throws `STALE_LEASE` unless [epoch] is the current generation.
  ///
  /// §8 warns that checking the epoch only at the request entry point is not enough,
  /// because an already in-flight request would otherwise keep writing. Callers must
  /// therefore re-assert this at each write, not once per request.
  void assertWritable(LeaseEpoch epoch) {
    if (epoch != _current) {
      throw ProtocolViolation(
        ProtocolErrorCode.staleLease,
        'write generation ${epoch.value} is not current (${_current.value})',
      );
    }
    if (!_current.isAllocated) {
      throw const ProtocolViolation(
        ProtocolErrorCode.staleLease,
        'no write generation has been allocated for this task',
      );
    }
  }

  bool isWritable(LeaseEpoch epoch) {
    try {
      assertWritable(epoch);
      return true;
    } on ProtocolViolation {
      return false;
    }
  }
}

/// Lifecycle of an idempotency record.
enum IdempotencyState {
  /// Accepted and still being processed; the peer should poll or retry with the same id.
  inFlight,

  /// Finished; the stored result is the answer for every later use of this id.
  completed,
}

/// The persisted outcome of one request id.
class IdempotencyRecord {
  IdempotencyRecord({
    required this.requestId,
    required this.requestDigest,
    required this.state,
    required this.leaseEpoch,
    this.result,
  });

  final String requestId;

  /// Digest of the request parameters, used to detect the same id carrying different
  /// content (§9).
  final String requestDigest;

  final IdempotencyState state;

  /// The generation in force when this request produced its result.
  final LeaseEpoch leaseEpoch;

  /// The stored semantic result, replayed verbatim.
  final Map<String, Object?>? result;

  @override
  String toString() =>
      'IdempotencyRecord($requestId, $requestDigest, ${state.name}, '
      '${leaseEpoch.value})';
}

/// What happened when a request id was presented.
enum IdempotencyOutcomeKind {
  /// Not seen before; the caller may proceed and must later record the result.
  fresh,

  /// Already completed with identical parameters; return the stored result unchanged.
  replay,

  /// Still in flight; answer 202 and let the peer retry the same id (§9).
  inFlight,

  /// The same id arrived with different parameters (§9).
  conflict,
}

/// The result of presenting a request id.
class IdempotencyOutcome {
  const IdempotencyOutcome(this.kind, [this.record]);

  final IdempotencyOutcomeKind kind;
  final IdempotencyRecord? record;

  /// The protocol error to answer a conflict with.
  ProtocolErrorCode? get errorCode => kind == IdempotencyOutcomeKind.conflict
      ? ProtocolErrorCode.requestIdConflict
      : null;

  @override
  String toString() => 'IdempotencyOutcome(${kind.name})';
}

/// In-memory idempotency records.
///
/// Deliberately storage-agnostic: T04-01 will back this with SQLite inside the same
/// transaction that commits the effect, which is the only way the record and the effect
/// cannot diverge.
class IdempotencyStore {
  final Map<String, IdempotencyRecord> _records = <String, IdempotencyRecord>{};

  int get length => _records.length;

  /// Presents a request id.
  ///
  /// [requestDigest] must be a stable digest of the request parameters; it is what makes
  /// "same id, different request" detectable.
  IdempotencyOutcome begin({
    required RequestScope scope,
    required String requestId,
    required String requestDigest,
    required LeaseEpoch leaseEpoch,
  }) {
    _validateRequestId(requestId);
    final IdempotencyRecord? existing = _records[_key(scope, requestId)];
    if (existing == null) {
      _records[_key(scope, requestId)] = IdempotencyRecord(
        requestId: requestId,
        requestDigest: requestDigest,
        state: IdempotencyState.inFlight,
        leaseEpoch: leaseEpoch,
      );
      return const IdempotencyOutcome(IdempotencyOutcomeKind.fresh);
    }

    if (existing.requestDigest != requestDigest) {
      return IdempotencyOutcome(IdempotencyOutcomeKind.conflict, existing);
    }
    return IdempotencyOutcome(
      existing.state == IdempotencyState.inFlight
          ? IdempotencyOutcomeKind.inFlight
          : IdempotencyOutcomeKind.replay,
      existing,
    );
  }

  /// Records the result of a previously accepted request.
  void complete({
    required RequestScope scope,
    required String requestId,
    required Map<String, Object?> result,
    required LeaseEpoch leaseEpoch,
  }) {
    final String key = _key(scope, requestId);
    final IdempotencyRecord? existing = _records[key];
    if (existing == null) {
      throw ProtocolViolation(
        ProtocolErrorCode.invalidState,
        'request $requestId was never accepted in this scope',
      );
    }
    _records[key] = IdempotencyRecord(
      requestId: requestId,
      requestDigest: existing.requestDigest,
      state: IdempotencyState.completed,
      leaseEpoch: leaseEpoch,
      result: Map<String, Object?>.unmodifiable(result),
    );
  }

  IdempotencyRecord? lookup(RequestScope scope, String requestId) =>
      _records[_key(scope, requestId)];

  String _key(RequestScope scope, String requestId) =>
      '${scope.transferId}|${scope.operation.name}|'
      '${scope.credentialFingerprint}|$requestId';

  static void _validateRequestId(String requestId) {
    // §9: the request id is a canonical UUID. Reusing the shared validator keeps a
    // single definition of "canonical".
    uuidToBytes(requestId, 'requestId');
  }
}

/// What a recovery attempt produced.
enum ResumeOutcomeKind {
  /// A new generation was allocated; proceed with the recovery.
  granted,

  /// The same request id was retried; the previous grant is returned **without**
  /// advancing the generation again (§9).
  replayed,

  /// The request is still being processed; answer 202 (§9).
  inFlight,

  /// The same request id arrived with different parameters (§9).
  conflict,

  /// A newer generation exists; do not hand back a writable token for the old one (§9).
  staleResumeRequest,
}

/// The result of a recovery attempt.
class ResumeOutcome {
  const ResumeOutcome(this.kind, {this.leaseEpoch, this.result});

  final ResumeOutcomeKind kind;

  /// The generation to use, present for [ResumeOutcomeKind.granted] and
  /// [ResumeOutcomeKind.replayed].
  final LeaseEpoch? leaseEpoch;

  /// The stored grant, replayed unchanged.
  final Map<String, Object?>? result;

  /// The protocol error to answer with, when the attempt did not succeed.
  ProtocolErrorCode? get errorCode {
    switch (kind) {
      case ResumeOutcomeKind.conflict:
        return ProtocolErrorCode.requestIdConflict;
      case ResumeOutcomeKind.staleResumeRequest:
        return ProtocolErrorCode.staleResumeRequest;
      case ResumeOutcomeKind.inFlight:
        return null; // 202, not an error
      case ResumeOutcomeKind.granted:
      case ResumeOutcomeKind.replayed:
        return null;
    }
  }

  @override
  String toString() =>
      'ResumeOutcome(${kind.name}, epoch=${leaseEpoch?.value})';
}

/// Applies §9's recovery rules on top of a [LeaseGuard] and an [IdempotencyStore].
class ResumeCoordinator {
  ResumeCoordinator({required this.guard, required this.store});

  final LeaseGuard guard;
  final IdempotencyStore store;

  /// Handles a `POST /transfers/{id}/resume`.
  ///
  /// The ordering matters and is enforced here:
  ///
  /// 1. a known request id with different parameters is a conflict;
  /// 2. a known request id still in flight answers 202;
  /// 3. a known **completed** request id is replayed, and if a newer generation has
  ///    since been allocated it is refused as `STALE_RESUME_REQUEST` rather than
  ///    replayed, because replaying it would hand back a writable token for a
  ///    superseded generation;
  /// 4. otherwise a new generation is allocated.
  ResumeOutcome resume({
    required RequestScope scope,
    required String requestId,
    required String requestDigest,
  }) {
    if (scope.operation != ProtocolOperation.resume) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'ResumeCoordinator only handles the resume operation',
      );
    }

    final IdempotencyRecord? existing = store.lookup(scope, requestId);

    if (existing != null) {
      if (existing.requestDigest != requestDigest) {
        return ResumeOutcome(
          ResumeOutcomeKind.conflict,
          result: existing.result,
        );
      }
      if (existing.state == IdempotencyState.inFlight) {
        return ResumeOutcome(
          ResumeOutcomeKind.inFlight,
          leaseEpoch: existing.leaseEpoch,
        );
      }
      if (guard.current > existing.leaseEpoch) {
        return ResumeOutcome(
          ResumeOutcomeKind.staleResumeRequest,
          leaseEpoch: existing.leaseEpoch,
          result: existing.result,
        );
      }
      if (guard.current < existing.leaseEpoch) {
        // The guard went backwards, which means two tasks shared a guard. Refuse rather
        // than pretend: silently granting would let writes from both generations land.
        throw const ProtocolViolation(
          ProtocolErrorCode.invalidState,
          'the lease guard is behind a granted generation; guards must not be shared',
        );
      }
      return ResumeOutcome(
        ResumeOutcomeKind.replayed,
        leaseEpoch: existing.leaseEpoch,
        result: existing.result,
      );
    }

    final LeaseEpoch granted = guard.revokeAndAdvance();
    final IdempotencyOutcome accepted = store.begin(
      scope: scope,
      requestId: requestId,
      requestDigest: requestDigest,
      leaseEpoch: granted,
    );
    if (accepted.kind != IdempotencyOutcomeKind.fresh) {
      throw StateError(
        'the store rejected a request id that was just looked up as absent',
      );
    }
    return ResumeOutcome(ResumeOutcomeKind.granted, leaseEpoch: granted);
  }

  /// Records the result of a granted recovery.
  void completeResume({
    required RequestScope scope,
    required String requestId,
    required Map<String, Object?> result,
  }) {
    final IdempotencyRecord? record = store.lookup(scope, requestId);
    if (record == null) {
      throw ProtocolViolation(
        ProtocolErrorCode.invalidState,
        'resume $requestId was never granted in this scope',
      );
    }
    store.complete(
      scope: scope,
      requestId: requestId,
      result: result,
      leaseEpoch: record.leaseEpoch,
    );
  }
}
