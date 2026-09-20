/// The `/v1` request surface: routing, and validating every parameter before use.
///
/// §7 opens with the rule this file exists to enforce:
///
/// > 所有 ID 参数须先解析校验。
///
/// and then lists nineteen method-and-path rows. Modelling them as data rather than as a
/// hand-written chain of string comparisons means the table can be checked against §7 in
/// a test, and means a parameter reaches business logic only after its shape has been
/// verified.
///
/// ## Two decisions worth stating
///
/// **Percent-encoding is refused anywhere in the request target.** Every value this
/// surface carries is an unescaped canonical form: a canonical UUID, a protocol decimal
/// string, a fixed word, or an opaque cursor this server produced. So a correct request
/// never needs an escape, and refusing one removes a whole class of bypass before it can
/// reach a matcher: `%2F` decoding into a separator would change how many segments a path
/// has, and `%2e%2e` decoding into `..` would turn a literal into a traversal. The check
/// is applied to the raw target, so it holds whether or not the HTTP layer decoded first.
///
/// The consequence for the cursor is worth naming: §7 calls it "返回的不透明值" without
/// fixing a format, so this reading requires the server to issue a cursor containing no
/// character that needs an escape. That constrains a format the draft leaves open, so it
/// is registered in `docs/PROJECT_LEDGER.md` §5 for confirmation.
///
/// **An unknown method on a known path answers `NOT_FOUND`.** §11's table has no 405, and
/// `AGENTS.md` §3 forbids inventing protocol detail, so the conservative reading is the
/// one §7 already states for unknown and unauthorised resources: "任务查询对无权限资源
/// 统一 404". That also declines to confirm which endpoints exist. The reading is recorded
/// in `docs/PROJECT_LEDGER.md` §5 for confirmation when the protocol is frozen.
///
/// ## What this file does not do
///
/// It does not read a body, decide authorisation, or produce a response. §7's rows are
/// modelled to the point where a request is known to be well formed and its parameters are
/// typed; everything after that belongs to the endpoint.
library;

import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/protocol_validation.dart';

/// The methods §7 uses.
enum HttpMethod { get, post, put }

/// The `kind` a manifest page request selects (§6).
enum ManifestPageKind {
  files('files'),
  chunks('chunks');

  const ManifestPageKind(this.wireValue);

  final String wireValue;

  static ManifestPageKind parse(String value) {
    for (final ManifestPageKind kind in ManifestPageKind.values) {
      if (kind.wireValue == value) {
        return kind;
      }
    }
    throw ProtocolViolation(
      ProtocolErrorCode.invalidField,
      'kind must be files or chunks',
    );
  }
}

/// One row of §7's table.
class ApiRoute {
  const ApiRoute({
    required this.name,
    required this.method,
    required this.template,
    this.allowedQuery = const <String>{},
    this.maxLimit,
  });

  /// A stable name for diagnostics, matching the endpoint's purpose.
  final String name;

  final HttpMethod method;

  /// The path with `{name}` placeholders, always under `/v1`.
  final String template;

  /// Query parameter names this endpoint accepts.
  ///
  /// Unknown names are refused rather than ignored, for the same reason §4 refuses an
  /// undefined JSON field: a parameter one implementation honours and another drops is a
  /// difference in behaviour that no test of either one would catch.
  final Set<String> allowedQuery;

  /// The largest `limit` this endpoint accepts, when it has one.
  final int? maxLimit;

  /// The template split into segments, without the empty one the leading slash produces.
  ///
  /// Kept in the same shape as a request path's segments, so matching is a straight
  /// index-by-index comparison rather than a comparison of two different conventions.
  List<String> get segments => template.split('/').sublist(1);

  /// The path parameter names, in order.
  List<String> get parameterNames => <String>[
    for (final String segment in segments)
      if (segment.startsWith('{') && segment.endsWith('}'))
        segment.substring(1, segment.length - 1),
  ];

  @override
  String toString() => '${method.name.toUpperCase()} $template';
}

/// A request whose route and parameters have been validated.
class MatchedApiRequest {
  MatchedApiRequest._({
    required this.route,
    required Map<String, String> path,
    required Map<String, String> query,
    required this.chunkIndex,
  }) : pathParameters = Map<String, String>.unmodifiable(path),
       queryParameters = Map<String, String>.unmodifiable(query);

  final ApiRoute route;

  /// Path parameters, already shape-checked.
  final Map<String, String> pathParameters;

  /// Query parameters, undecoded and already name-checked.
  final Map<String, String> queryParameters;

  /// The chunk index from the path, when the route has one.
  final int? chunkIndex;

  /// The transfer the request targets. Every route except `/v1/pair` has one.
  String? get transferId => pathParameters['id'];

  /// The file the request targets, when the route has one.
  String? get fileId => pathParameters['fid'] ?? queryParameters['fileId'];

  /// The page size to use, defaulted and bounded for this route.
  ///
  /// A requested limit is honoured only when it is within the endpoint's maximum, and the
  /// maximum is not a suggestion: §6 caps a file page at 128 items and a chunk page at
  /// 1024, "并同时受 1 MiB 上限约束".
  int pageLimit() {
    final int max = _effectiveMaxLimit();
    final String? requested = queryParameters['limit'];
    if (requested == null) {
      return max;
    }
    final int value = parseJsonInteger(int.tryParse(requested), 'limit');
    if (value < 1 || value > max) {
      throw ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'limit must be between 1 and $max for this endpoint',
      );
    }
    return value;
  }

  /// Where a page starts, as a protocol decimal string, defaulting to 0.
  int startIndex() {
    final String? raw = queryParameters['startIndex'];
    if (raw == null) {
      return 0;
    }
    return parseDecimalString(raw, 'startIndex');
  }

  /// The `kind` of a manifest page request, which §6 requires to be present.
  ///
  /// §6 states the pairing too: "files 页不得带 fileId，chunks 页必须带 fileId". Both halves
  /// are checked here, because a page whose kind and fileId disagree is a page whose
  /// meaning two implementations would read differently.
  ManifestPageKind manifestKind() {
    final String? raw = queryParameters['kind'];
    if (raw == null) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'a manifest page request must name kind',
      );
    }
    final ManifestPageKind kind = ManifestPageKind.parse(raw);
    final bool hasFileId = queryParameters.containsKey('fileId');
    if (kind == ManifestPageKind.files && hasFileId) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'a files page must not carry a fileId',
      );
    }
    if (kind == ManifestPageKind.chunks && !hasFileId) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'a chunks page must carry a fileId',
      );
    }
    if (hasFileId) {
      uuidToBytes(queryParameters['fileId'], 'fileId');
    }
    return kind;
  }

  /// The manifest page kind, or null when the route is not a manifest page request.
  ManifestPageKind? get manifestPageKindOrNull {
    final String? raw = queryParameters['kind'];
    return raw == null ? null : ManifestPageKind.parse(raw);
  }

  /// `afterSeq` for the control poll, as a protocol decimal string, defaulting to 0.
  int afterSeq() {
    final String? raw = queryParameters['afterSeq'];
    if (raw == null) {
      return 0;
    }
    return parseDecimalString(raw, 'afterSeq');
  }

  /// The byte offset of [chunkIndex] in a file of [sizeBytes].
  ///
  /// §8: "块索引从 URL 十进制解析，offset = index × 4194304，乘法先检查范围，不能接受客户端
  /// 任意 offset". The offset is therefore always derived, never read from the request, and
  /// the range check happens before the multiplication can overflow.
  int chunkOffsetBytes({required int sizeBytes}) => chunkOffsetForIndex(
    sizeBytes,
    ProtocolLimits.chunkSizeBytes,
    chunkIndex!,
  );

  int _effectiveMaxLimit() {
    final int? routeMax = route.maxLimit;
    if (routeMax == null) {
      throw ProtocolViolation(
        ProtocolErrorCode.invalidField,
        '${route.template} does not take a limit',
      );
    }
    if (routeMax != _kindDependentLimit) {
      return routeMax;
    }
    // A manifest page's cap depends on what it pages over, so the kind decides it, and
    // §6 makes the kind mandatory rather than inferred.
    final ManifestPageKind? kind = manifestPageKindOrNull;
    if (kind == null) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'a manifest page request must name kind before a page size can be chosen',
      );
    }
    return kind == ManifestPageKind.chunks
        ? ProtocolLimits.chunkPageLimit
        : ProtocolLimits.filePageLimit;
  }

  @override
  String toString() =>
      'MatchedApiRequest($route, path=$pathParameters, '
      'query=$queryParameters)';
}

/// Marks a route whose page cap depends on `kind`.
const int _kindDependentLimit = -1;

/// The nineteen rows of §7's table.
abstract final class ApiRoutes {
  /// §7 fixes the prefix.
  static const String prefix = '/v1';

  static const ApiRoute pair = ApiRoute(
    name: 'pair',
    method: HttpMethod.post,
    template: '$prefix/pair',
  );

  static const ApiRoute offers = ApiRoute(
    name: 'offers',
    method: HttpMethod.get,
    template: '$prefix/offers',
    allowedQuery: <String>{'cursor'},
  );

  static const ApiRoute createTransfer = ApiRoute(
    name: 'createTransfer',
    method: HttpMethod.post,
    template: '$prefix/transfers',
  );

  static const ApiRoute putManifest = ApiRoute(
    name: 'putManifest',
    method: HttpMethod.put,
    template: '$prefix/transfers/{id}/manifest',
  );

  static const ApiRoute getManifest = ApiRoute(
    name: 'getManifest',
    method: HttpMethod.get,
    template: '$prefix/transfers/{id}/manifest',
    allowedQuery: <String>{'kind', 'fileId', 'startIndex', 'limit'},
    maxLimit: _kindDependentLimit,
  );

  static const ApiRoute seal = ApiRoute(
    name: 'seal',
    method: HttpMethod.post,
    template: '$prefix/transfers/{id}/seal',
  );

  static const ApiRoute decision = ApiRoute(
    name: 'decision',
    method: HttpMethod.post,
    template: '$prefix/transfers/{id}/decision',
  );

  static const ApiRoute authorization = ApiRoute(
    name: 'authorization',
    method: HttpMethod.get,
    template: '$prefix/transfers/{id}/authorization',
  );

  static const ApiRoute authorizationReceipt = ApiRoute(
    name: 'authorizationReceipt',
    method: HttpMethod.post,
    template: '$prefix/transfers/{id}/authorization/receipt',
  );

  static const ApiRoute resume = ApiRoute(
    name: 'resume',
    method: HttpMethod.post,
    template: '$prefix/transfers/{id}/resume',
  );

  static const ApiRoute status = ApiRoute(
    name: 'status',
    method: HttpMethod.get,
    template: '$prefix/transfers/{id}/status',
    allowedQuery: <String>{'fileId', 'startIndex', 'limit'},
    maxLimit: ProtocolLimits.chunkPageLimit,
  );

  static const ApiRoute putChunk = ApiRoute(
    name: 'putChunk',
    method: HttpMethod.put,
    template: '$prefix/transfers/{id}/files/{fid}/chunks/{index}',
  );

  static const ApiRoute getChunk = ApiRoute(
    name: 'getChunk',
    method: HttpMethod.get,
    template: '$prefix/transfers/{id}/files/{fid}/chunks/{index}',
  );

  static const ApiRoute checkpoint = ApiRoute(
    name: 'checkpoint',
    method: HttpMethod.post,
    template: '$prefix/transfers/{id}/checkpoint',
  );

  static const ApiRoute pause = ApiRoute(
    name: 'pause',
    method: HttpMethod.post,
    template: '$prefix/transfers/{id}/pause',
  );

  static const ApiRoute complete = ApiRoute(
    name: 'complete',
    method: HttpMethod.post,
    template: '$prefix/transfers/{id}/complete',
  );

  static const ApiRoute cancel = ApiRoute(
    name: 'cancel',
    method: HttpMethod.post,
    template: '$prefix/transfers/{id}/cancel',
  );

  static const ApiRoute control = ApiRoute(
    name: 'control',
    method: HttpMethod.get,
    template: '$prefix/transfers/{id}/control',
    allowedQuery: <String>{'afterSeq'},
  );

  static const ApiRoute controlReceipt = ApiRoute(
    name: 'controlReceipt',
    method: HttpMethod.post,
    template: '$prefix/transfers/{id}/control/receipt',
  );

  /// Every row of §7's table, in the order the table lists them.
  static const List<ApiRoute> all = <ApiRoute>[
    pair,
    offers,
    createTransfer,
    putManifest,
    getManifest,
    seal,
    decision,
    authorization,
    authorizationReceipt,
    resume,
    status,
    putChunk,
    getChunk,
    checkpoint,
    pause,
    complete,
    cancel,
    control,
    controlReceipt,
  ];

  /// Matches a request target, validating every parameter before returning.
  ///
  /// [target] is the path plus an optional query string, exactly as it arrived. Nothing is
  /// percent-decoded here: a parameter that needed decoding is refused rather than
  /// guessed at.
  static MatchedApiRequest match({
    required HttpMethod method,
    required String target,
  }) {
    if (target.contains('%')) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidPath,
        'a request path must not be percent-encoded; every parameter the protocol uses '
        'is an unescaped canonical form',
      );
    }

    final int question = target.indexOf('?');
    final String path = question == -1 ? target : target.substring(0, question);
    final String queryString = question == -1
        ? ''
        : target.substring(question + 1);

    if (!path.startsWith('$prefix/')) {
      throw ProtocolViolation(
        ProtocolErrorCode.notFound,
        'the request path is not under $prefix',
      );
    }
    final List<String> segments = path.substring(1).split('/');
    if (segments.any((String s) => s.isEmpty)) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidPath,
        'a request path must not contain an empty segment',
      );
    }
    for (final String segment in segments) {
      if (segment == '.' || segment == '..') {
        throw const ProtocolViolation(
          ProtocolErrorCode.invalidPath,
          'a request path must not contain a dot segment',
        );
      }
    }

    final ApiRoute? route = _matchRoute(method, segments);
    if (route == null) {
      // See the library comment: §11 has no 405, and §7 already answers unknown resources
      // with 404 without confirming which endpoints exist.
      throw const ProtocolViolation(
        ProtocolErrorCode.notFound,
        'no endpoint answers that method and path',
      );
    }

    final Map<String, String> pathParameters = <String, String>{};
    final List<String> templateSegments = route.segments;
    int? chunkIndex;
    for (int i = 0; i < templateSegments.length; i++) {
      final String template = templateSegments[i];
      if (!template.startsWith('{')) {
        continue;
      }
      final String name = template.substring(1, template.length - 1);
      final String value = segments[i];
      switch (name) {
        case 'id':
        case 'fid':
          // §4: identifiers are canonical lowercase UUIDs, and §7 requires them to be
          // parsed and validated before anything uses them.
          uuidToBytes(value, name == 'id' ? 'transferId' : 'fileId');
        case 'index':
          chunkIndex = parseDecimalString(value, 'chunk index');
          if (chunkIndex >= ProtocolLimits.maxChunksPerTransfer) {
            throw ProtocolViolation(
              ProtocolErrorCode.invalidField,
              'the chunk index is outside 0..'
              '${ProtocolLimits.maxChunksPerTransfer - 1}',
            );
          }
        default:
          throw ProtocolViolation(
            ProtocolErrorCode.invalidField,
            'unknown path parameter $name',
          );
      }
      pathParameters[name] = value;
    }

    return MatchedApiRequest._(
      route: route,
      path: pathParameters,
      query: _parseQuery(queryString, route),
      chunkIndex: chunkIndex,
    );
  }

  static ApiRoute? _matchRoute(HttpMethod method, List<String> segments) {
    for (final ApiRoute route in all) {
      if (route.method != method) {
        continue;
      }
      final List<String> template = route.segments;
      if (template.length != segments.length) {
        continue;
      }
      bool matches = true;
      for (int i = 0; i < template.length; i++) {
        final String expected = template[i];
        if (expected.startsWith('{')) {
          continue;
        }
        if (expected != segments[i]) {
          matches = false;
          break;
        }
      }
      if (matches) {
        return route;
      }
    }
    return null;
  }

  static Map<String, String> _parseQuery(String queryString, ApiRoute route) {
    final Map<String, String> out = <String, String>{};
    if (queryString.isEmpty) {
      return out;
    }
    for (final String pair in queryString.split('&')) {
      final int equals = pair.indexOf('=');
      if (equals <= 0) {
        throw const ProtocolViolation(
          ProtocolErrorCode.invalidField,
          'every query parameter must have a name and a value',
        );
      }
      final String name = pair.substring(0, equals);
      final String value = pair.substring(equals + 1);
      if (!route.allowedQuery.contains(name)) {
        throw ProtocolViolation(
          ProtocolErrorCode.invalidField,
          '${route.template} does not take a "$name" parameter',
        );
      }
      if (out.containsKey(name)) {
        throw ProtocolViolation(
          ProtocolErrorCode.invalidField,
          'the "$name" parameter appears more than once',
        );
      }
      out[name] = value;
    }
    return out;
  }
}
