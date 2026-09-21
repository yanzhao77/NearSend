/// The HTTPS transport: TLS termination and §8 framing in front of [ControlPipeline].
///
/// ## What the engine enforces, and what this file enforces
///
/// `docs/protocol/v1.0-draft1.md` §8 fixes framing rules whose whole point is that two hops
/// must agree on where a message ends. `dart:io` parses HTTP itself, so some of those shapes
/// are settled before any of this code runs. That was measured rather than assumed
/// (`tooling/spikes/http_framing/main.dart`, raw sockets against a `dart:io` server):
///
/// | what the peer sends | what the handler sees |
/// | --- | --- |
/// | two `Content-Length` headers | **refused by the engine**; the handler never runs |
/// | two spellings of `Content-Length` | **refused by the engine** |
/// | `Transfer-Encoding: chunked` | **accepted and de-chunked**; the header is still visible |
/// | `Content-Length` + `Transfer-Encoding` | engine frames by chunks and **removes `Content-Length` from the map** |
/// | `Content-Encoding: gzip` | header visible; the body is **not** decompressed |
/// | `Content-Length: 005` | normalized to `5` |
///
/// The fourth row is the one worth stating plainly: an implementation that wanted to refuse
/// "both present" by observing both **cannot**, because one of them is gone by the time our
/// code runs. It is refused anyway - rejecting any `Transfer-Encoding` at all covers it - so
/// the rule holds, but for a different reason than the one §8's wording suggests.
/// [assertSupportedFraming] checks are therefore written as consequences rather than as a
/// re-implementation of the engine's parser.
///
/// ## Why the body cap is not the protocol's rule
///
/// §4 caps a control body at 1 MiB and §8 requires a chunk body to be exactly one chunk.
/// The transport cannot apply either, because it does not know the route yet; it applies a
/// single generous backstop instead and lets `decodeControlBody` and
/// [assertChunkBodyLength] apply the real rules once the route is known. A transport that
/// guessed the route would be a second router, which is the thing §7's single
/// `ApiRoutes.match` exists to avoid.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:nearsend/core/network/control_message.dart';
import 'package:nearsend/core/network/control_pipeline.dart';
import 'package:nearsend/core/protocol/api_routes.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/security/tls_identity.dart';

/// The largest request body the transport will buffer, whatever the route.
///
/// One chunk (§5's 4 MiB) plus slack for headers the framing layer has already removed,
/// since the largest legitimate body here is a chunk `PUT`. Anything a route accepts is
/// strictly smaller, and the route's own rule is applied later.
const int transportBodyBackstopBytes =
    ProtocolLimits.chunkSizeBytes + (64 * 1024);

/// Serves the `/v1` control API over TLS.
///
/// The server owns the listening socket and nothing else: no session state, no tasks, no
/// credentials. Everything it receives becomes a [ControlRequest] and is handed to the
/// pipeline, which is the only place §7's stages live.
class HttpsControlServer {
  HttpsControlServer({
    required this.identity,
    required this.pipeline,
    InternetAddress? address,
    this.port = 0,
  }) : address = address ?? InternetAddress.anyIPv4;

  /// The certificate and key this server presents. Its pin is what the QR code carries.
  final TlsIdentity identity;

  /// §7's stages, up to the endpoint boundary.
  final ControlPipeline pipeline;

  /// The local address to bind. Defaults to every IPv4 interface, because the peer is on
  /// the LAN and the QR code's candidate address is chosen from the interfaces, not here.
  final InternetAddress address;

  /// The port to bind; `0` asks the system for a free one.
  final int port;

  HttpServer? _server;

  /// The bound port, available after [start].
  int get boundPort {
    final HttpServer? server = _server;
    if (server == null) {
      throw StateError('the server has not been started');
    }
    return server.port;
  }

  /// The addresses a client could use to reach this server, for §3's QR candidates.
  ///
  /// Read from the live socket rather than from a stored string, so a candidate cannot
  /// name an interface the server is not actually listening on.
  InternetAddress get boundAddress =>
      _server?.address ?? InternetAddress.anyIPv4;

  bool get isRunning => _server != null;

  /// Binds and starts accepting connections.
  ///
  /// §2's floor is applied to the context, not to each connection: a connection that
  /// cannot negotiate TLS 1.3 is refused during the handshake, before any HTTP request
  /// exists.
  Future<void> start() async {
    if (_server != null) {
      throw StateError('the server is already running on port $boundPort');
    }
    final SecurityContext context = SecurityContext()
      ..useCertificateChainBytes(identity.certificatePem)
      ..usePrivateKeyBytes(identity.privateKeyPem)
      ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_3;

    final HttpServer server = await HttpServer.bindSecure(
      address,
      port,
      context,
      shared: false,
    );
    _server = server;
    unawaited(
      server
          .listen(
            _handle,
            onError: (Object _) {
              // A transport-level error is per-connection: the socket is already gone, so there
              // is nowhere to send a §7 error body and nothing to do but keep serving. It is
              // deliberately not logged with the request, because the request may carry a token.
            },
          )
          .asFuture<void>(),
    );
  }

  /// Stops accepting connections and closes the listener.
  Future<void> stop() async {
    final HttpServer? server = _server;
    _server = null;
    await server?.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    final ControlResponse response = await _respond(request);

    try {
      request.response.statusCode = response.status;
      response.headers.forEach((String name, String value) {
        // dart:io sets Content-Length from the body it is given; setting it here as well
        // would be a second opinion about the same fact.
        if (name == 'content-length') {
          return;
        }
        request.response.headers.set(name, value);
      });
      request.response.add(response.body);
      await request.response.close();
    } on Object {
      // The peer disconnected mid-response. There is nothing to answer and nothing to
      // recover; the request itself was already handled or refused.
    }
  }

  /// Turns one socket request into one §7 response, including the transport's own refusals.
  Future<ControlResponse> _respond(HttpRequest request) async {
    try {
      assertSupportedFraming(request.headers);
      final Uint8List body = await _readBody(request);
      return await pipeline.handle(
        ControlRequest(
          method: _method(request.method),
          target: request.uri.toString(),
          headers: _headerMap(request.headers),
          body: body,
          // §3's per-source failure limit needs the caller's address. It is read here because
          // this is the only layer that has it; it travels on the request and is never used
          // as an identity.
          peerAddress: request.connectionInfo?.remoteAddress.address,
        ),
      );
    } on ProtocolViolation catch (violation) {
      // A framing refusal is answered in §7's shape rather than by dropping the connection,
      // so the peer learns which rule it broke. §8's "关闭连接" is satisfied as well: the
      // request is never routed, and `dart:io` closes the socket once this response is sent.
      return ControlResponse.violation(violation);
    }
  }

  Future<Uint8List> _readBody(HttpRequest request) async {
    final int declared = request.contentLength;
    if (declared > transportBodyBackstopBytes) {
      throw ProtocolViolation(
        ProtocolErrorCode.bodyTooLarge,
        'the declared body is $declared bytes, over the transport backstop of '
        '$transportBodyBackstopBytes',
      );
    }

    final BytesBuilder builder = BytesBuilder(copy: false);
    await for (final List<int> part in request) {
      builder.add(part);
      if (builder.length > transportBodyBackstopBytes) {
        // Checked while reading rather than after, so a peer that understates its length
        // cannot make this buffer grow without bound.
        throw ProtocolViolation(
          ProtocolErrorCode.bodyTooLarge,
          'the body exceeded the transport backstop of '
          '$transportBodyBackstopBytes bytes',
        );
      }
    }
    return builder.takeBytes();
  }
}

/// Refuses the framings §8 does not support, on the parsed header map.
///
/// Exposed rather than private so the rules can be tested against a literal header map
/// without a socket, the same shape `chunk_headers.dart` uses.
///
/// The duplicate-`Content-Length` check is **unreachable through `dart:io`**, which refuses
/// that shape before a handler runs (see the measurement table above). It is kept because
/// the cost of keeping it is one comparison, and because a future transport that does its
/// own parsing would need it.
void assertSupportedFraming(HttpHeaders headers) {
  final List<String> transferEncoding =
      headers['transfer-encoding'] ?? const <String>[];
  if (transferEncoding.isNotEmpty) {
    // §8: "不支持 Transfer-Encoding". Refused for every value, including `identity`:
    // `identity` is a claim about compression, and what §8 refuses is the header existing.
    throw ProtocolViolation(
      ProtocolErrorCode.invalidField,
      '§8 does not support Transfer-Encoding, and it was present as '
      '$transferEncoding',
    );
  }

  final List<String> contentEncoding =
      headers['content-encoding'] ?? const <String>[];
  if (contentEncoding.isNotEmpty &&
      !(contentEncoding.length == 1 &&
          contentEncoding.single.toLowerCase() == 'identity')) {
    // §8: "不允许压缩". dart:io does not decompress request bodies (measured), so this is
    // refused on the header rather than trusted to be a no-op.
    throw ProtocolViolation(
      ProtocolErrorCode.invalidField,
      '§8 does not allow a compressed body, and Content-Encoding was present as '
      '$contentEncoding',
    );
  }

  final List<String> contentLength =
      headers['content-length'] ?? const <String>[];
  if (contentLength.length > 1) {
    throw ProtocolViolation(
      ProtocolErrorCode.invalidField,
      '§8 requires a single Content-Length, and ${contentLength.length} were present',
    );
  }
}

/// Maps an HTTP method name onto §7's three verbs.
///
/// Anything else answers `NOT_FOUND`. §11's table has no 405, and §7 already answers
/// `NOT_FOUND` for resources that must not be confirmed to exist; the same reading keeps a
/// peer from learning which methods this build knows.
HttpMethod _method(String name) => switch (name.toUpperCase()) {
  'GET' => HttpMethod.get,
  'POST' => HttpMethod.post,
  'PUT' => HttpMethod.put,
  _ => throw ProtocolViolation(
    ProtocolErrorCode.notFound,
    'the method is not one of §7\'s three verbs',
  ),
};

/// Flattens `dart:io`'s multi-valued header map into the single-valued map the protocol
/// layer takes.
///
/// [ControlRequest] lowercases and rejects two spellings of one name, so a repeated header
/// whose values differ cannot be silently collapsed here: the first value is kept and the
/// rest are joined, which makes the duplication visible to that check instead of hidden.
Map<String, String> _headerMap(HttpHeaders headers) {
  final Map<String, String> out = <String, String>{};
  headers.forEach((String name, List<String> values) {
    if (values.isEmpty) {
      return;
    }
    out[name] = values.length == 1 ? values.single : values.join(', ');
  });
  return out;
}
