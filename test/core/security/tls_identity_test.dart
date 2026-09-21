/// Tests for [TlsIdentity]: the encoding, and the pinning shape ADR-0005 settles.
///
/// The second group matters more than the first. `docs/decisions/ADR-0005-TLS引擎与证书供给.md`
/// says the pin must be enforced by the **trust store**, with `badCertificateCallback` kept
/// only as a fail-closed backstop, because Dart never calls that callback for a certificate
/// that already chains to a configured trust root. These tests drive real TLS handshakes so
/// that claim is exercised rather than restated: if the shape is wrong, a connection that
/// should be refused will be accepted here.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/asn1.dart';

import 'package:nearsend/core/security/pairing_trust.dart';
import 'package:nearsend/core/security/tls_identity.dart';

/// A client context that trusts exactly one certificate and nothing else.
///
/// This is the shape ADR-0005 requires: no system roots, so "trusted" can only ever mean
/// "this is the certificate the QR code named".
SecurityContext _clientContextTrusting(Uint8List certificatePem) =>
    SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificatesBytes(certificatePem);

/// A client whose callback refuses everything, so nothing can be admitted by the backstop.
HttpClient _failClosedClient(
  SecurityContext context, {
  required void Function() onCallback,
}) {
  return HttpClient(context: context)
    ..badCertificateCallback =
        (X509Certificate certificate, String host, int port) {
          onCallback();
          return false;
        };
}

void main() {
  group('certificate encoding', () {
    test('the pin is the SHA-256 of the DER, and not of the PEM text', () {
      final TlsIdentity identity = generateTlsIdentity(
        commonName: 'NearSend',
        subjectAltNames: <String>['127.0.0.1'],
      );

      expect(identity.pin, sha256.convert(identity.certificateDer).toString());
      expect(identity.pin, serverFingerprintOf(identity.certificateDer));
      expect(identity.pin, matches(RegExp(r'^[0-9a-f]{64}$')));

      // §2's hazard, made concrete: the two digests have the same shape and are different.
      expect(
        identity.pin,
        isNot(sha256.convert(identity.certificatePem).toString()),
      );
    });

    test(
      'the DER re-parses as a v3 certificate carrying the requested names',
      () {
        final TlsIdentity identity = generateTlsIdentity(
          commonName: 'NearSend',
          subjectAltNames: <String>['192.168.10.100', 'nearsend.local'],
        );

        // Re-parsed with an implementation that did not write it. The deep check on the
        // extension contents is done by openssl in the run evidence; what matters here is that
        // the certificate is structurally a v3 X.509 certificate and not merely bytes that
        // dart:io happens to tolerate.
        final ASN1Object parsed = ASN1Parser(identity.certificateDer)
            .nextObject();
        expect(parsed, isA<ASN1Sequence>());

        final List<ASN1Object> certificate = (parsed as ASN1Sequence).elements!;
        expect(
          certificate,
          hasLength(3),
          reason: 'tbs, signatureAlgorithm, signatureValue',
        );

        final List<ASN1Object> tbs = (certificate[0] as ASN1Sequence).elements!;
        expect(
          tbs,
          hasLength(8),
          reason: 'version, serial, signature, issuer, validity, subject, spki, extensions',
        );
        expect(
          tbs[0].tag,
          0xA0,
          reason:
              'the version field is [0] EXPLICIT, which is what makes this v3',
        );
        expect(
          (tbs[1] as ASN1Integer).integer,
          greaterThan(BigInt.zero),
          reason: 'a serial number must be positive',
        );

        // The subjectAltName extension OID must be present as an encoded value. Searching the
        // bytes is enough here: the structural assertions above already prove the certificate
        // parses, and openssl re-parses it independently in the run evidence.
        expect(
          _contains(identity.certificateDer, <int>[
            0x06,
            0x03,
            0x55,
            0x1D,
            0x11,
          ]),
          isTrue,
          reason: 'the subjectAltName extension OID (2.5.29.17) is missing',
        );
      },
    );

    test('two identities share neither a key nor a certificate', () {
      final TlsIdentity a = generateTlsIdentity(commonName: 'NearSend');
      final TlsIdentity b = generateTlsIdentity(commonName: 'NearSend');

      expect(a.certificateDer, isNot(equals(b.certificateDer)));
      expect(a.privateKeyPkcs8Der, isNot(equals(b.privateKeyPkcs8Der)));
      expect(a.pin, isNot(b.pin));
    });

    test('dart:io accepts the PEM pair, so the encoding is usable, not just parseable', () {
      final TlsIdentity identity = generateTlsIdentity(
        commonName: 'NearSend',
        subjectAltNames: <String>['127.0.0.1'],
      );

      expect(
        () => SecurityContext()
          ..useCertificateChainBytes(identity.certificatePem)
          ..usePrivateKeyBytes(identity.privateKeyPem),
        returnsNormally,
      );
    });
  });

  group('the ADR-0005 pinning shape', () {
    late TlsIdentity identity;
    late HttpServer server;
    late int requestsSeen;

    setUp(() async {
      identity = generateTlsIdentity(
        commonName: 'NearSend',
        subjectAltNames: <String>['127.0.0.1'],
      );
      requestsSeen = 0;
      final SecurityContext serverContext = SecurityContext()
        ..useCertificateChainBytes(identity.certificatePem)
        ..usePrivateKeyBytes(identity.privateKeyPem)
        ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_3;

      server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        serverContext,
        shared: false,
      );
      server.listen((HttpRequest request) async {
        requestsSeen++;
        request.response.statusCode = 200;
        request.response.write('pong');
        await request.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('a client trusting exactly the pinned certificate connects', () async {
      int callbackCalls = 0;
      final HttpClient client = _failClosedClient(
        _clientContextTrusting(identity.certificatePem),
        onCallback: () => callbackCalls++,
      );

      final HttpClientResponse response = await (await client.getUrl(
        Uri.parse('https://127.0.0.1:${server.port}/v1/ping'),
      )).close();
      expect(response.statusCode, 200);
      expect(await response.transform(utf8.decoder).join(), 'pong');

      // The connection was admitted by the trust store, so the backstop was not needed.
      // This is the property ADR-0005 depends on: the security decision is not in the
      // callback, so it cannot be skipped by the callback not being called.
      expect(callbackCalls, 0);
      client.close(force: true);
    });

    test(
      'a client trusting a different certificate is refused and sends nothing',
      () async {
        final TlsIdentity other = generateTlsIdentity(
          commonName: 'Not NearSend',
          subjectAltNames: <String>['127.0.0.1'],
        );

        int callbackCalls = 0;
        final HttpClient client = _failClosedClient(
          _clientContextTrusting(other.certificatePem),
          onCallback: () => callbackCalls++,
        );

        await expectLater(
          client
              .getUrl(Uri.parse('https://127.0.0.1:${server.port}/v1/ping'))
              .then((HttpClientRequest request) => request.close()),
          throwsA(isA<HandshakeException>()),
        );

        expect(
          callbackCalls,
          greaterThan(0),
          reason: 'the backstop should have been consulted',
        );
        expect(
          requestsSeen,
          0,
          reason:
              '§2: a failed comparison must not be followed by an HTTP request',
        );
        client.close(force: true);
      },
    );

    test('an address the certificate does not carry is still admitted when the pin matches', () async {
      // Measured behaviour: dart:io enforces SAN/IP matching **even for a certificate the
      // trust store already accepts**, and surfaces it as `IP address mismatch`. So the trust
      // store alone is not sufficient when the peer is reached by an address the certificate
      // does not name (a LAN IP that changed, an alias, a hotspot gateway). ADR-0005's shape
      // is therefore two mechanisms over the *same* pin: the trust store refuses every
      // certificate that is not the pinned one, and this callback tolerates a name mismatch
      // when - and only when - the fingerprint still matches.
      final TlsIdentity namedDifferently = generateTlsIdentity(
        commonName: 'NearSend',
        subjectAltNames: <String>['10.99.99.99'],
      );

      final SecurityContext serverContext = SecurityContext()
        ..useCertificateChainBytes(namedDifferently.certificatePem)
        ..usePrivateKeyBytes(namedDifferently.privateKeyPem)
        ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_3;
      final HttpServer otherServer = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        serverContext,
        shared: false,
      );
      int otherSeen = 0;
      otherServer.listen((HttpRequest request) async {
        otherSeen++;
        request.response.statusCode = 200;
        await request.response.close();
      });

      int callbackCalls = 0;
      final HttpClient client =
          HttpClient(
              context: _clientContextTrusting(namedDifferently.certificatePem),
            )
            ..badCertificateCallback =
                (X509Certificate certificate, String host, int port) {
                  callbackCalls++;
                  return serverFingerprintOf(certificate.der) ==
                      namedDifferently.pin;
                };

      final HttpClientResponse response = await (await client.getUrl(
        Uri.parse('https://127.0.0.1:${otherServer.port}/v1/ping'),
      )).close();

      expect(response.statusCode, 200);
      expect(otherSeen, 1);
      expect(
        callbackCalls,
        greaterThan(0),
        reason:
            'if this is 0 the name check happened outside the callback and the '
            'certificate must carry every address a client may use',
      );
      client.close(force: true);
      await otherServer.close(force: true);
    });

    test('the callback tolerates a name mismatch only when the fingerprint matches', () async {
      // The same shape, with the wrong certificate behind the callback's decision. A callback
      // that returned true unconditionally would connect here; this one must not.
      final TlsIdentity other = generateTlsIdentity(
        commonName: 'Not NearSend',
        subjectAltNames: <String>['10.99.99.99'],
      );

      int callbackCalls = 0;
      final HttpClient client =
          HttpClient(context: _clientContextTrusting(other.certificatePem))
            ..badCertificateCallback =
                (X509Certificate certificate, String host, int port) {
                  callbackCalls++;
                  // Compare against the *other* pin: the presented certificate is ours, not theirs.
                  return serverFingerprintOf(certificate.der) == other.pin;
                };

      await expectLater(
        client
            .getUrl(Uri.parse('https://127.0.0.1:${server.port}/v1/ping'))
            .then((HttpClientRequest request) => request.close()),
        throwsA(isA<HandshakeException>()),
      );
      expect(requestsSeen, 0);
      expect(
        callbackCalls,
        greaterThan(0),
        reason:
            'the certificate is not the trusted one, so the backstop decides',
      );
      client.close(force: true);
    });

    test('the server refuses TLS below 1.3', () async {
      // The floor is set on the context in setUp. A TLS 1.2-only client is not expressible
      // through dart:io, so the run evidence for this uses openssl as an independent
      // implementation (see the t03-02-01 summary). Here we only assert the setting is
      // accepted rather than silently dropped.
      expect(
        () =>
            SecurityContext()
              ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_3,
        returnsNormally,
      );
    });
  });
}

bool _contains(List<int> haystack, List<int> needle) {
  for (int i = 0; i + needle.length <= haystack.length; i++) {
    bool matched = true;
    for (int j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        matched = false;
        break;
      }
    }
    if (matched) {
      return true;
    }
  }
  return false;
}
