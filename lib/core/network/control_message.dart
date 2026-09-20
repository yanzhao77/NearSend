/// The control-plane request and response envelope of §7.
///
/// ## What this file is for
///
/// §7 states two rules about *every* control response, and neither had an implementation:
///
/// > 成功体中的 token 字段只出现在专门授权/恢复响应，**所有控制响应 Cache-Control: no-store**。
///
/// > 错误体 {code,message,retryable,requestId?}，message 不含密钥或完整本地路径。
///
/// The second is answered by [WireError], which refuses to accept a message at all. The
/// first is answered here, and it is made **structural** rather than conventional for the
/// same reason: a rule that every future call site has to remember is a rule that will be
/// forgotten once, on the one response that matters.
///
/// [ControlResponse] therefore has no way to omit `Cache-Control: no-store` and no way to
/// override it. Every constructor adds it last, so a caller who passes their own
/// `Cache-Control` silently loses to it, and the header map is unmodifiable so it cannot be
/// removed afterwards. There is deliberately no `ControlResponse.raw`.
///
/// ## Why the content type is fixed
///
/// §4 fixes the control body as "application/json; charset=utf-8" with a 1 MiB limit in each
/// direction. Both are enforced when a body is written, so this build cannot emit a control
/// response its own parser would refuse.
///
/// ## What this file does not do
///
/// It does not read the transport, parse a target, or decide anything about credentials. A
/// [ControlRequest] arrives after TLS has terminated and after the bytes have been framed;
/// §8's framing rules ([ChunkPutHeaders]) are applied by the layer that reads the body.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:nearsend/core/protocol/api_routes.dart';
import 'package:nearsend/core/protocol/chunk_headers.dart';
import 'package:nearsend/core/protocol/json_body.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/protocol/wire_error.dart';

/// The media type §4 fixes for a control body.
const String controlContentType = 'application/json; charset=utf-8';

/// The header name §7 requires on every control response.
const String cacheControlNoStore = 'Cache-Control: no-store';

/// A request as the service sees it: TLS is already terminated and the body is framed.
///
/// Header lookup is case-insensitive, which HTTP requires and which a plain `Map` does not
/// give. The map is stored lowercased once rather than being searched with a folding
/// comparison at each call site, so no lookup can accidentally be case-sensitive.
class ControlRequest {
  ControlRequest({
    required this.method,
    required this.target,
    Map<String, String> headers = const <String, String>{},
    Uint8List? body,
  }) : headers = _lowercaseHeaders(headers),
       body = body ?? emptyBody;

  /// A shared empty body, so a request without one allocates nothing.
  static final Uint8List emptyBody = Uint8List(0);

  final HttpMethod method;

  /// The request target exactly as it arrived: path plus optional query string.
  final String target;

  /// Headers, keyed by lowercased name.
  final Map<String, String> headers;

  /// The framed body. For a control request this is at most 1 MiB (§4); for a chunk `PUT` it
  /// is one chunk, whose exact length §8 requires.
  final Uint8List body;

  /// A header value, or null when absent. [name] is matched case-insensitively.
  String? header(String name) => headers[name.toLowerCase()];

  /// The `Authorization` header's token, or null when the header is absent.
  ///
  /// A malformed header throws, because §7 makes a well-formed bearer part of the contract
  /// and treating garbage as "absent" would let two implementations disagree about whether a
  /// credential was presented. An absent header is different: [BearerHeader.parse] is only
  /// called when something is there.
  String? bearerToken() {
    final String? value = header('authorization');
    if (value == null) {
      return null;
    }
    return BearerHeader.parse(value);
  }

  /// Decodes the body as a control body, applying every §4 rule.
  ///
  /// Delegates to [decodeControlBody] rather than calling `jsonDecode`: that function
  /// rejects duplicate object keys, a BOM, invalid UTF-8 and over-deep nesting, none of which
  /// `jsonDecode` does on its own.
  Map<String, Object?> decodeJsonBody({String scope = 'the control body'}) =>
      decodeControlBody(body, scope: scope);

  @override
  String toString() =>
      'ControlRequest(${method.name.toUpperCase()} $target, ${body.length}B)';
}

/// A control-plane response.
///
/// Constructed only through the factories, so the two rules §7 states for every control
/// response hold by construction: `Cache-Control: no-store` is always present, and a JSON
/// body is always `application/json; charset=utf-8` and within §4's 1 MiB limit.
class ControlResponse {
  ControlResponse._({
    required this.status,
    required Map<String, String> headers,
    required this.body,
  }) : headers = Map<String, String>.unmodifiable(<String, String>{
         // Lowercased caller headers first, then the required one last: a caller who passes
         // their own Cache-Control loses to §7 rather than silently overriding it.
         ..._lowercaseHeaders(headers),
         'cache-control': 'no-store',
       });

  /// A control response carrying a JSON body.
  factory ControlResponse.json({
    required int status,
    required Map<String, Object?> body,
    Map<String, String> headers = const <String, String>{},
  }) => ControlResponse._(
    status: status,
    headers: <String, String>{...headers, 'content-type': controlContentType},
    body: _encodeControlBody(body),
  );

  /// The response §7 prescribes for [code], with the body from [WireError].
  ///
  /// The status comes from §11's table, so an error can never be emitted with a status that
  /// disagrees with its code. [retryAfterSeconds] is required for, and only for, a 429: §11
  /// makes the backoff the prescribed behaviour, and a limit with no delay leaves a client
  /// with nothing to obey.
  factory ControlResponse.error(
    ProtocolErrorCode code, {
    String? requestId,
    int? retryAfterSeconds,
    Map<String, String> headers = const <String, String>{},
  }) {
    if (code == ProtocolErrorCode.rateLimited) {
      if (retryAfterSeconds == null || retryAfterSeconds <= 0) {
        throw ArgumentError.value(
          retryAfterSeconds,
          'retryAfterSeconds',
          '§11 makes a 429 carry a positive Retry-After',
        );
      }
    } else if (retryAfterSeconds != null) {
      throw ArgumentError.value(
        retryAfterSeconds,
        'retryAfterSeconds',
        'only RATE_LIMITED carries Retry-After; ${code.wireCode} does not',
      );
    }

    return ControlResponse._(
      status: code.httpStatus,
      headers: <String, String>{
        ...headers,
        'content-type': controlContentType,
        if (retryAfterSeconds != null) 'retry-after': '$retryAfterSeconds',
      },
      body: _encodeControlBody(
        WireError.of(code, requestId: requestId).toJson(),
      ),
    );
  }

  /// The response for a local protocol violation.
  ///
  /// A [ProtocolViolation] carries the code its author chose, and those codes are wired to
  /// statuses by §11, so the answer is the code's own.
  factory ControlResponse.violation(
    ProtocolViolation violation, {
    String? requestId,
  }) => ControlResponse.error(violation.code, requestId: requestId);

  /// A response carrying raw bytes, for the chunk endpoints of §8.
  ///
  /// Separate from [ControlResponse.json] because §8's chunk body is
  /// `application/octet-stream` and is one 4 MiB chunk, which §4's 1 MiB control-body limit
  /// does not apply to.
  factory ControlResponse.binary({
    required int status,
    required Uint8List body,
    Map<String, String> headers = const <String, String>{},
  }) => ControlResponse._(
    status: status,
    headers: <String, String>{
      ...headers,
      'content-type': chunkContentType,
      'content-length': '${body.length}',
    },
    body: body,
  );

  final int status;

  /// Response headers, keyed by lowercased name. Always carries `cache-control: no-store`.
  final Map<String, String> headers;

  final Uint8List body;

  /// Whether the body is §4's JSON control body.
  bool get isControlBody => headers['content-type'] == controlContentType;

  /// The decoded body, when this response carries one.
  Map<String, Object?> decodeJsonBody() => decodeControlBody(body);

  /// The error body, when this response is an error.
  WireError decodeError() {
    final Map<String, Object?> json = decodeJsonBody();
    return WireError.parse(json);
  }

  @override
  String toString() => 'ControlResponse($status, ${body.length}B)';
}

/// Encodes a control body, refusing one this build's own parser would reject.
///
/// §4 caps a control body at 1 MiB in each direction. Writing a larger one would produce a
/// response the peer must refuse, which is worse than failing here where the cause is still
/// visible.
Uint8List _encodeControlBody(Map<String, Object?> body) {
  final Uint8List bytes = Uint8List.fromList(utf8.encode(jsonEncode(body)));
  if (bytes.length > ProtocolLimits.controlBodyMaxBytes) {
    throw ProtocolViolation(
      ProtocolErrorCode.resourceLimit,
      'the control body is ${bytes.length} bytes, over the '
      '${ProtocolLimits.controlBodyMaxBytes} byte limit §4 sets for a response',
    );
  }
  return bytes;
}

Map<String, String> _lowercaseHeaders(Map<String, String> headers) {
  if (headers.isEmpty) {
    return const <String, String>{};
  }
  final Map<String, String> out = <String, String>{};
  headers.forEach((String name, String value) {
    final String lowered = name.toLowerCase();
    if (out.containsKey(lowered)) {
      // Two spellings of one header is the same condition §8 refuses for
      // Content-Length: a map cannot hold both, so silently keeping one means choosing a
      // value on the sender's behalf.
      throw ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'the header "$name" was supplied twice under different spellings',
      );
    }
    out[lowered] = value;
  });
  return out;
}
