// S0 spike: does the TLS engine this project needs actually work?
//
// `docs/protocol/v1.0-draft1.md` §2 asks for two things that are easy to get subtly wrong:
//
// 1. TLS 1.3 is a **minimum**, not a preference: "协商不到最低版本立即终止，不降级明文".
// 2. The pin is `SHA-256(leaf certificate DER)`, and it must be compared for **every**
//    certificate — "即使证书受系统 CA 信任也必须比对 pin，不能只在'不可信证书回调'中比对".
//
// The second sentence is the reason this probe exists. `HttpClient.badCertificateCallback` is
// the obvious place to compare a fingerprint, and it is the wrong place on its own: it only
// fires for certificates the configured trust store does not already accept. A client that
// relies on it alone accepts any CA-issued certificate for the host without ever comparing a
// pin. Scenario C below demonstrates exactly that, using this same client code.
//
// Run:
//   dart run tooling/spikes/tls_engine/main.dart <dir-with-cert.pem-and-key.pem>
//
// This probe is exploratory. Its verified conclusions are recorded in
// `docs/decisions/ADR-0005-TLS引擎与证书供给.md`; the mechanics that survive become ordinary
// tests under `test/core/security/`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const String _pemCertBegin = '-----BEGIN CERTIFICATE-----';
const String _pemCertEnd = '-----END CERTIFICATE-----';

Future<void> main(List<String> args) async {
  final List<String> positional = args
      .where((String a) => !a.startsWith('--'))
      .toList();
  final int holdSeconds =
      args
          .where((String a) => a.startsWith('--hold='))
          .map((String a) => int.parse(a.substring('--hold='.length)))
          .firstOrNull ??
      0;
  final int fixedPort =
      args
          .where((String a) => a.startsWith('--port='))
          .map((String a) => int.parse(a.substring('--port='.length)))
          .firstOrNull ??
      0;

  if (positional.length != 1) {
    stderr.writeln(
      'usage: main.dart <dir containing cert.pem and key.pem> [--hold=SECONDS]',
    );
    exit(2);
  }

  final Directory dir = Directory(positional.single);
  final File certFile = File('${dir.path}${Platform.pathSeparator}cert.pem');
  final File keyFile = File('${dir.path}${Platform.pathSeparator}key.pem');
  if (!certFile.existsSync() || !keyFile.existsSync()) {
    stderr.writeln('cert.pem and key.pem must both exist in ${dir.path}');
    exit(2);
  }

  final Uint8List leafDer = _pemToDer(certFile.readAsStringSync());
  final Uint8List realPin = Uint8List.fromList(sha256.convert(leafDer).bytes);
  final Uint8List wrongPin = Uint8List.fromList(realPin)..[0] ^= 0xFF;

  stdout.writeln('leaf DER bytes      : ${leafDer.length}');
  stdout.writeln('pin SHA-256(DER)    : ${_hex(realPin)}');
  stdout.writeln(
    'PEM file SHA-256    : '
    '${sha256.convert(certFile.readAsBytesSync())}',
  );

  // ---------------------------------------------------------------------------------------
  // The server half: §2's minimum version, on a real listening socket.
  // ---------------------------------------------------------------------------------------
  final SecurityContext serverContext = SecurityContext()
    ..useCertificateChainBytes(certFile.readAsBytesSync())
    ..usePrivateKeyBytes(keyFile.readAsBytesSync())
    ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_3;

  int requestsSeen = 0;
  final HttpServer server = await HttpServer.bindSecure(
    InternetAddress.loopbackIPv4,
    fixedPort,
    serverContext,
    shared: false,
  );
  final int port = server.port;
  unawaited(
    server.listen((HttpRequest request) async {
      requestsSeen++;
      request.response.statusCode = 200;
      request.response.write('pong');
      await request.response.close();
    }).asFuture<void>(),
  );
  stdout.writeln('\nserver listening on 127.0.0.1:$port (minimum TLS 1.3)');

  if (holdSeconds > 0) {
    // External verification hook: with the socket held open, a TLS version can be probed by a
    // different implementation (`openssl s_client -tls1_2` must be refused, `-tls1_3` accepted).
    // Verifying our own minimum with our own client would be circular.
    stdout.writeln('HOLDING for ${holdSeconds}s on port $port');
    await Future<void>.delayed(Duration(seconds: holdSeconds));
    await server.close(force: true);
    return;
  }

  // ---------------------------------------------------------------------------------------
  // A: empty trust store, correct pin. The pin comparison is the ONLY thing that admits it.
  // ---------------------------------------------------------------------------------------
  final _Attempt a = await _attempt(
    port: port,
    expectedPin: realPin,
    trustRoots: false,
  );
  stdout.writeln('\n[A] empty trust store + correct pin');
  stdout.writeln('    result         : ${a.summary}');
  stdout.writeln(
    '    verdict        : ${a.succeeded && a.callbackCalls >= 1 ? 'PASS (admitted by our own comparison, not by a trust store)' : 'FAIL'}',
  );
  final int afterA = requestsSeen;

  // ---------------------------------------------------------------------------------------
  // B: empty trust store, wrong pin. Must fail, and must send no HTTP request at all.
  // ---------------------------------------------------------------------------------------
  final _Attempt b = await _attempt(
    port: port,
    expectedPin: wrongPin,
    trustRoots: false,
  );
  stdout.writeln('\n[B] empty trust store + wrong pin');
  stdout.writeln('    result         : ${b.summary}');
  stdout.writeln(
    '    verdict        : ${!b.succeeded && requestsSeen == afterA ? 'PASS (refused, and the server saw no request)' : 'FAIL'}',
  );

  // ---------------------------------------------------------------------------------------
  // C: the hazard. A default client that trusts the certificate never calls our comparison.
  // ---------------------------------------------------------------------------------------
  final _Attempt c = await _attempt(
    port: port,
    expectedPin: realPin,
    trustRoots: true,
    extraTrustedCert: certFile.path,
  );
  stdout.writeln('\n[C] CA-style trust + correct pin (the hazard)');
  stdout.writeln('    result         : ${c.summary}');
  stdout.writeln(
    '    verdict        : ${c.succeeded && c.callbackCalls == 0 ? 'CONFIRMED: this shape compares NO pin' : 'unexpected'}',
  );

  stdout.writeln('\nserver saw $requestsSeen HTTP request(s) in total');

  await server.close(force: true);
}

/// One client attempt, reporting whether the request completed and how often our own
/// certificate callback ran.
Future<_Attempt> _attempt({
  required int port,
  required Uint8List expectedPin,
  required bool trustRoots,
  String? extraTrustedCert,
}) async {
  final SecurityContext context = SecurityContext(withTrustedRoots: trustRoots);
  if (extraTrustedCert != null) {
    context.setTrustedCertificates(extraTrustedCert);
  }

  int callbackCalls = 0;
  final HttpClient client = HttpClient(context: context);
  client.badCertificateCallback =
      (X509Certificate certificate, String host, int port) {
        callbackCalls++;
        // §2: the pin is over the leaf certificate's complete DER, not its PEM text and not its
        // SPKI. `certificate.der` is that DER.
        return _hex(sha256.convert(certificate.der).bytes) == _hex(expectedPin);
      };

  try {
    final HttpClientRequest request = await client.getUrl(
      Uri.parse('https://127.0.0.1:$port/v1/ping'),
    );
    final HttpClientResponse response = await request.close();
    final String body = await response.transform(utf8.decoder).join();
    return _Attempt(
      succeeded: true,
      callbackCalls: callbackCalls,
      summary:
          'completed status=${response.statusCode} body=$body '
          'callbackCalls=$callbackCalls',
    );
  } on Object catch (error) {
    return _Attempt(
      succeeded: false,
      callbackCalls: callbackCalls,
      summary: 'refused ${error.runtimeType} callbackCalls=$callbackCalls',
    );
  } finally {
    client.close(force: true);
  }
}

final class _Attempt {
  const _Attempt({
    required this.succeeded,
    required this.callbackCalls,
    required this.summary,
  });

  final bool succeeded;
  final int callbackCalls;
  final String summary;
}

/// Decodes the first certificate of a PEM file to its DER bytes.
Uint8List _pemToDer(String pem) {
  final int begin = pem.indexOf(_pemCertBegin);
  final int end = pem.indexOf(_pemCertEnd);
  if (begin < 0 || end < 0 || end <= begin) {
    throw const FormatException('the PEM file has no CERTIFICATE block');
  }
  final String base64Body = pem
      .substring(begin + _pemCertBegin.length, end)
      .replaceAll(RegExp(r'\s'), '');
  return Uint8List.fromList(base64.decode(base64Body));
}

String _hex(List<int> bytes) =>
    bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();
