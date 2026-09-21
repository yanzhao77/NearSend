/// The client half of the control transport: a pinned HTTPS connection to one server.
///
/// ## Why the pin lives in the callback here, and in the trust store elsewhere
///
/// ADR-0005 requires the fingerprint comparison to be impossible to skip. Where it *can* be
/// placed depends on what the client already has, and the pairing flow fixes that:
/// §3's QR payload carries `serverFingerprint` and **not** the certificate, so before the
/// first handshake the client has a 64-hex digest and nothing to put in a trust store.
///
/// So the shape is: `SecurityContext(withTrustedRoots: false)` - an empty trust store - plus a
/// callback that compares `SHA-256(certificate.der)` against the pin. With no trusted roots,
/// **every** certificate fails pre-verification, so the callback necessarily runs for every
/// certificate; there is no certificate that can be admitted without our comparison. That is
/// the property the earlier probe measured as scenario A and B
/// (`docs/testing/evidence/2026-09-21/t03-02-01/`), and the reason the "trusted certificate
/// never reaches the callback" hazard cannot apply here.
///
/// The complementary shape - the certificate *is* known, so it goes in the trust store and the
/// callback only covers a name mismatch - is what `tls_identity_test.dart` exercises, and what
/// a reconnecting client that persisted the certificate would use.
///
/// ## What this client refuses to do
///
/// §2: no redirects are followed, and no credential is sent to whatever a redirect names. The
/// minimum TLS version is 1.3 on this side too, so a peer that cannot meet it fails the
/// handshake rather than being negotiated down.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:nearsend/core/network/control_message.dart';
import 'package:nearsend/core/protocol/json_body.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/wire_error.dart';
import 'package:nearsend/core/security/pairing_trust.dart';

/// A control response as received, which is not the same thing as one we sent.
///
/// [ControlResponse] makes guarantees about what *this* build emits - `Cache-Control:
/// no-store` is always present, the body is always within §4's cap. A peer's response makes
/// none of those, so it gets its own type rather than a constructor on [ControlResponse] that
/// would have to weaken them.
class ReceivedControlResponse {
  ReceivedControlResponse({
    required this.status,
    required Map<String, String> headers,
    required this.body,
  }) : headers = Map<String, String>.unmodifiable(<String, String>{
         for (final MapEntry<String, String> e in headers.entries)
           e.key.toLowerCase(): e.value,
       });

  final int status;

  /// Response headers, keyed by lowercased name.
  final Map<String, String> headers;

  final Uint8List body;

  int get bodyBytes => body.length;

  /// Whether the status is a success status.
  bool get isSuccess => status >= 200 && status < 300;

  Map<String, Object?> decodeJsonBody() => decodeControlBody(body);

  /// The error body, when this response is an error.
  WireError decodeError() => WireError.parse(decodeJsonBody());

  @override
  String toString() => 'ReceivedControlResponse($status, ${body.length}B)';
}

/// How a connection attempt ended, so a caller can tell a refused pin from a refused
/// handshake without parsing a message.
enum PinnedConnectionOutcome {
  /// The certificate's fingerprint matched the pin.
  pinMatched,

  /// A certificate was presented and its fingerprint did not match.
  pinMismatched,
}

/// Sends §7 control requests to one pinned server.
///
/// One instance is one server identity and one connection pool. §2 requires the trust context
/// to be per-connection on the *server*'s side of the pairing handshake; here the pin is fixed
/// for the lifetime of the client, and [PairingHandshake] remains the thing that gates the
/// credential release.
class HttpsControlClient {
  HttpsControlClient({
    required this.pin,
    required this.host,
    required this.port,
    this.onCertificateSeen,
  }) {
    _context = SecurityContext(withTrustedRoots: false)
      ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_3;
    _client = HttpClient(context: _context)
      ..autoUncompress = false
      ..connectionTimeout = const Duration(seconds: 10)
      ..badCertificateCallback = _decideCertificate;
  }

  /// The pin from the QR code: `SHA-256(server leaf DER)` as lowercase hex (§2).
  final String pin;

  /// The candidate address the client chose. §3 says choosing a candidate must not be able
  /// to bypass the pin, which holds here because the pin is a constructor argument and no
  /// connection result can change it.
  final String host;

  final int port;

  /// Called with the outcome of the certificate decision, for diagnostics and tests.
  final void Function(PinnedConnectionOutcome outcome)? onCertificateSeen;

  late final SecurityContext _context;
  late final HttpClient _client;

  /// Whether any certificate has been presented on this client so far.
  ///
  /// A wrong pin that produced `false` here never reached the server, which is the property
  /// §2 states as "比对失败关闭连接" - worth being able to assert rather than infer.
  bool get sawAnyCertificate => _sawAnyCertificate;
  bool _sawAnyCertificate = false;

  bool _decideCertificate(
    X509Certificate certificate,
    String certHost,
    int certPort,
  ) {
    _sawAnyCertificate = true;
    // §2: `SHA-256` over the leaf's complete DER. `X509Certificate.der` is that encoding; it
    // is not the PEM text and not the SPKI.
    final bool matches = serverFingerprintOf(certificate.der) == pin;
    onCertificateSeen?.call(
      matches
          ? PinnedConnectionOutcome.pinMatched
          : PinnedConnectionOutcome.pinMismatched,
    );
    // The trust store is empty, so this return value is the only thing that can admit the
    // connection. Returning false on a mismatch therefore closes it before any request.
    //
    // A name mismatch on a certificate whose fingerprint *does* match is accepted on purpose:
    // ADR-0005 settles that the pin is the identity, so an address the certificate does not
    // name (a LAN IP that changed, an alias) must not be able to refuse a pinned peer.
    return matches;
  }

  /// Sends one request and returns what came back.
  ///
  /// Throws [ProtocolViolation] with `AUTH_EXPIRED` when the pinned handshake fails, because
  /// from the caller's point of view a connection whose peer could not prove its identity is
  /// a connection that must be re-paired rather than retried.
  Future<ReceivedControlResponse> send(ControlRequest request) async {
    final Uri uri = Uri.parse('https://$host:$port${request.target}');
    final HttpClientRequest httpRequest;
    try {
      httpRequest = await _client.openUrl(
        request.method.name.toUpperCase(),
        uri,
      );
    } on HandshakeException {
      throw const ProtocolViolation(
        ProtocolErrorCode.pairRejected,
        'the peer did not present the certificate named by the pairing fingerprint',
      );
    }

    // §2: no redirects. A 3xx answered by a pinned peer is not something to follow, and
    // following one would send the credential to an origin the pin says nothing about.
    httpRequest.followRedirects = false;
    request.headers.forEach(httpRequest.headers.set);

    // §8 refuses `Transfer-Encoding` outright, and `dart:io` falls back to chunked encoding
    // whenever the content length is unknown. Declaring the length is therefore not an
    // optimisation: leaving it unset makes this client send a request the peer is required to
    // refuse. Set even for an empty body, so no request ever carries a chunked frame.
    httpRequest.contentLength = request.body.length;
    if (request.body.isNotEmpty) {
      httpRequest.add(request.body);
    }

    final HttpClientResponse response = await httpRequest.close();
    final Uint8List body = await _collect(response);
    final Map<String, String> headers = <String, String>{};
    response.headers.forEach((String name, List<String> values) {
      if (values.isNotEmpty) {
        headers[name] = values.join(', ');
      }
    });

    return ReceivedControlResponse(
      status: response.statusCode,
      headers: headers,
      body: body,
    );
  }

  Future<Uint8List> _collect(HttpClientResponse response) async {
    final BytesBuilder builder = BytesBuilder(copy: false);
    await for (final List<int> part in response) {
      builder.add(part);
    }
    return builder.takeBytes();
  }

  /// Closes the connection pool. The pin survives; the sockets do not.
  void close() {
    _client.close(force: true);
  }
}
