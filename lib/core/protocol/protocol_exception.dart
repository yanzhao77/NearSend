/// The protocol error model, `docs/protocol/v1.0-draft1.md` §7 and §11.
///
/// §7 fixes the wire error body as `{code, message, retryable, requestId?}`, so
/// "can this be retried" is part of the contract and must be decided per code
/// rather than left to each caller. §11 pairs every code with an HTTP status and a
/// prescribed behaviour, and `docs/architecture/SYSTEM_ARCHITECTURE.md` §11 adds the
/// scope, a safe user-message key, diagnostic context and a cause.
///
/// `AGENTS.md` §5 forbids surfacing a raw platform exception as a protocol error and
/// forbids logging keys or full local paths, which is why the user-facing part is a
/// message *key* rather than a formatted string.
library;

/// Where an error occurred, from `SYSTEM_ARCHITECTURE.md` §11.
///
/// Scope decides blast radius: an identity or manifest-level failure must pause the
/// whole task, while a single file's read or export failure must let the other files
/// continue (`APP_AND_SERVICE_DESIGN.md` §11).
enum ErrorScope {
  /// The whole transfer is affected.
  task,

  /// One file is affected; the rest of the queue may continue.
  file,

  /// One chunk is affected; it can be re-requested.
  chunk,

  /// A platform capability failed (storage, network binding, permissions).
  platform,

  /// The peer violated the protocol.
  protocol,
}

/// Stable protocol error codes with their HTTP status, retryability and message key.
///
/// The `retryable` values are read off §11's behaviour column: codes whose prescribed
/// behaviour is to back off are retryable unchanged, and codes whose behaviour asks a
/// human or a new identity to intervene are not. Getting this wrong in either
/// direction is harmful - retrying a `MANIFEST_MISMATCH` forever hides corruption,
/// and refusing to retry a `STORAGE_SYNC_FAILED` turns a transient disk hiccup into
/// a failed transfer.
enum ProtocolErrorCode {
  // --- 400: the request itself is wrong; do not resend it unchanged. ---
  invalidField('INVALID_FIELD', 400, false, 'protocol.invalidField'),
  invalidDecimal('INVALID_DECIMAL', 400, false, 'protocol.invalidDecimal'),
  invalidPath('INVALID_PATH', 400, false, 'protocol.invalidPath'),

  // --- 401: identity must be re-established; never send old credentials to a
  // new identity (§11). ---
  pairRejected('PAIR_REJECTED', 401, false, 'protocol.pairRejected'),
  authExpired('AUTH_EXPIRED', 401, false, 'protocol.authExpired'),
  resumeRejected('RESUME_REJECTED', 401, false, 'protocol.resumeRejected'),

  // --- 403: the direction is not permitted for this task. ---
  directionForbidden(
    'DIRECTION_FORBIDDEN',
    403,
    false,
    'protocol.directionForbidden',
  ),

  // --- 404: unknown and unauthorised tasks are deliberately indistinguishable. ---
  notFound('NOT_FOUND', 404, false, 'protocol.notFound'),

  // --- 409: query state and stop the old writer; resending is not the fix. ---
  staleLease('STALE_LEASE', 409, false, 'protocol.staleLease'),
  requestIdConflict(
    'REQUEST_ID_CONFLICT',
    409,
    false,
    'protocol.requestIdConflict',
  ),
  snapshotExpired('SNAPSHOT_EXPIRED', 409, false, 'protocol.snapshotExpired'),
  invalidState('INVALID_STATE', 409, false, 'protocol.invalidState'),
  staleResumeRequest(
    'STALE_RESUME_REQUEST',
    409,
    false,
    'protocol.staleResumeRequest',
  ),

  // --- 410: do not silently create a duplicate task. ---
  taskExpired('TASK_EXPIRED', 410, false, 'protocol.taskExpired'),
  taskCancelled('TASK_CANCELLED', 410, false, 'protocol.taskCancelled'),

  // --- 413: shrink the task or page correctly. ---
  resourceLimit('RESOURCE_LIMIT', 413, false, 'protocol.resourceLimit'),
  bodyTooLarge('BODY_TOO_LARGE', 413, false, 'protocol.bodyTooLarge'),

  // --- 422: block or repair from the correct source; never retry indefinitely. ---
  manifestMismatch(
    'MANIFEST_MISMATCH',
    422,
    false,
    'protocol.manifestMismatch',
  ),
  chunkHashMismatch(
    'CHUNK_HASH_MISMATCH',
    422,
    false,
    'protocol.chunkHashMismatch',
  ),
  sourceChanged('SOURCE_CHANGED', 422, false, 'protocol.sourceChanged'),

  // --- 429: back off for Retry-After seconds. Retryable unchanged. ---
  rateLimited('RATE_LIMITED', 429, true, 'protocol.rateLimited'),

  // --- 500: nothing was acknowledged; the state stays recoverable, so the same
  // request may be retried. §11 explicitly says the commit is not confirmed. ---
  storageSyncFailed(
    'STORAGE_SYNC_FAILED',
    500,
    true,
    'protocol.storageSyncFailed',
  ),
  dbCommitFailed('DB_COMMIT_FAILED', 500, true, 'protocol.dbCommitFailed'),

  // --- 507: retryable, but only after the user frees space or changes location. ---
  spaceInsufficient(
    'SPACE_INSUFFICIENT',
    507,
    false,
    'protocol.spaceInsufficient',
  );

  const ProtocolErrorCode(
    this.wireCode,
    this.httpStatus,
    this.retryable,
    this.messageKey,
  );

  /// The exact string used in protocol error bodies.
  final String wireCode;

  /// The HTTP status §11 pairs with this code.
  final int httpStatus;

  /// Whether the *same* request may be retried without intervention.
  ///
  /// This is the value that goes into the wire `retryable` field. It is deliberately
  /// not "will it work eventually": `SPACE_INSUFFICIENT` can succeed after the user
  /// acts, but resending it unchanged cannot.
  final bool retryable;

  /// Stable key for the safe, localised user message.
  ///
  /// A key rather than a string: §7 requires the message to carry no secret and no
  /// full local path, and the UI layer owns the wording.
  final String messageKey;

  /// Looks up a code by its wire string, or returns null.
  static ProtocolErrorCode? fromWireCode(String wireCode) {
    for (final ProtocolErrorCode code in ProtocolErrorCode.values) {
      if (code.wireCode == wireCode) {
        return code;
      }
    }
    return null;
  }
}

/// A fully described protocol error, ready to be logged, mapped to a response or
/// turned into a typed domain failure.
class ProtocolError implements Exception {
  ProtocolError({
    required this.code,
    required this.scope,
    this.diagnosticContext = const <String, String>{},
    this.cause,
  });

  /// Builds an error from a validation failure raised by the encoders.
  factory ProtocolError.fromViolation(
    ProtocolViolation violation, {
    ErrorScope scope = ErrorScope.protocol,
  }) => ProtocolError(code: violation.code, scope: scope, cause: violation);

  final ProtocolErrorCode code;
  final ErrorScope scope;

  /// Structured, non-sensitive context such as a chunk index or a short task id.
  ///
  /// Never keys, tokens, recovery secrets, full local paths or file contents.
  final Map<String, String> diagnosticContext;

  /// The underlying failure, if any. Never rendered to the user.
  final Object? cause;

  /// Whether the same request may be retried, taken from the code.
  bool get retryable => code.retryable;

  /// HTTP status for the response, taken from the code.
  int get httpStatus => code.httpStatus;

  /// Whether this failure must pause the whole task rather than one file.
  ///
  /// `APP_AND_SERVICE_DESIGN.md` §11: identity or manifest-level problems pause the
  /// task; a single file's read or export failure lets the others continue.
  bool get pausesWholeTask =>
      scope == ErrorScope.task ||
      scope == ErrorScope.protocol ||
      code == ProtocolErrorCode.manifestMismatch ||
      code == ProtocolErrorCode.sourceChanged;

  @override
  String toString() {
    final String context = diagnosticContext.isEmpty
        ? ''
        : ' ${diagnosticContext.entries.map((MapEntry<String, String> e) => '${e.key}=${e.value}').join(' ')}';
    return '${code.wireCode} (${code.httpStatus}, scope=${scope.name}, '
        'retryable=${code.retryable})$context';
  }
}

/// Thrown when input must be rejected before it can be encoded or trusted.
///
/// Carrying a stable code matters: `AGENTS.md` §5 forbids presenting a raw
/// platform exception as a protocol error, and callers must be able to react to
/// the code rather than parse a message.
class ProtocolViolation implements Exception {
  const ProtocolViolation(this.code, this.detail);

  final ProtocolErrorCode code;

  /// Human-readable context for diagnostics. Must never contain a secret, a
  /// token or the content of a user file.
  final String detail;

  @override
  String toString() => '${code.wireCode}: $detail';
}
