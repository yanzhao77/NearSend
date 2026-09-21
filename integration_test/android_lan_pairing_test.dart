/// Runs on an Android device and talks to the real server over the real LAN.
///
/// This file exists because three of this task's questions have no local answer:
///
/// 1. Does Android's `X509Certificate.der` produce the **same** `SHA-256` Windows did when it
///    generated the certificate? If the two platforms disagreed about that encoding, a pin
///    would match on one machine and never on the other, and every test on the desktop would
///    still be green.
/// 2. Does `badCertificateCallback` run at the same points on Android?
/// 3. Can the app reach this machine at all over Wi-Fi?
///
/// The QR payload is passed in verbatim and parsed by the *same* strict parser a scanner would
/// use, so nothing is stubbed and the pin under test is the one the server really published.
///
/// The QR payload is passed in base64 and decoded here, rather than as raw JSON through
/// `--dart-define`: the payload is full of quotes and braces, and every layer between this
/// command line and the compiled test - PowerShell, `flutter test`, the ADB launch - is a
/// chance for those to be mangled. Base64 has no such characters, so a decoding failure is a
/// clear failure instead of a payload that is merely wrong.
///
/// Run (server first, then):
///   `flutter test integration_test/android_lan_pairing_test.dart -d <deviceId>`
///   with `--dart-define=NS_HOST=192.168.10.100` and `--dart-define=NS_QR_B64=<base64>`
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:nearsend/core/network/control_message.dart';
import 'package:nearsend/core/security/pair_request.dart';
import 'package:nearsend/core/network/https_control_client.dart';
import 'package:nearsend/core/protocol/api_routes.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/security/pairing_payload.dart';
import 'package:nearsend/core/security/pairing_service.dart';

const String _host = String.fromEnvironment('NS_HOST');
const String _qrBase64 = String.fromEnvironment('NS_QR_B64');

String get _qrJson => utf8.decode(base64.decode(_qrBase64));

/// Records a fact about the run.
///
/// Best effort on purpose. `flutter test` on a device does not forward the test isolate's
/// stdout to the console, and the device's own logcat is not a reliable channel either, so
/// these lines are for a developer watching a terminal and nothing is asserted on them. The
/// **assertions** are the evidence: a printed fingerprint can be wrong while a checked one
/// cannot, and the check here is that the value Android computed equals the one Windows
/// published.
void _record(String line) => stdout.writeln(line);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // Recorded so a run log carries the platform facts next to the result; a conclusion about
    // "Android agrees with Windows" is worth much less without them.
    _record('DEVICE_OS=${Platform.operatingSystem}');
    _record('DEVICE_OS_VERSION=${Platform.operatingSystemVersion}');
    _record('DEVICE_DART=${Platform.version}');
    _record('DEVICE_HOSTNAME=${Platform.localHostname}');
    _record('SERVER_HOST=$_host');
  });

  test('Android and the server agree on the certificate fingerprint', () async {
    expect(
      _qrBase64.isNotEmpty,
      isTrue,
      reason: 'pass --dart-define=NS_QR_B64=<the base64 of the payload the server printed>',
    );
    expect(
      _host.isNotEmpty,
      isTrue,
      reason: 'pass --dart-define=NS_HOST=<server ip>',
    );

    // Exactly what a scanner does: the payload is strict-parsed before anything is trusted.
    final PairingPayload payload = PairingPayload.parse(_qrJson);
    final PairingCandidate candidate = payload.candidates.first;
    _record('QR_SESSION=${payload.sessionId}');
    _record('QR_PIN=${payload.serverFingerprint}');
    _record('QR_CANDIDATE=${candidate.host}:${candidate.port}');

    final List<String> presentations = <String>[];
    final HttpsControlClient client = HttpsControlClient(
      pin: payload.serverFingerprint,
      host: _host,
      port: candidate.port,
      onCertificateSeen: (PinnedConnectionOutcome outcome, String presented) {
        presentations.add(presented);
        _record('CERT_SEEN=${outcome.name} $presented');
      },
    );

    final ReceivedControlResponse paired = await client.send(
      _pairRequest(payload),
    );
    _record('PAIR_STATUS=${paired.status}');

    expect(
      paired.status,
      200,
      reason: 'body: ${utf8.decode(paired.body, allowMalformed: true)}',
    );
    expect(
      presentations,
      isNotEmpty,
      reason: 'the callback must have run on Android for our comparison to exist at all',
    );
    expect(
      presentations.every((String p) => p == payload.serverFingerprint),
      isTrue,
      reason:
          'Android computed a fingerprint that differs from the one Windows published: '
          '${presentations.join(', ')} vs ${payload.serverFingerprint}',
    );

    // The token from the response then authorises a real state change.
    final String sessionToken = PairResponse.parse(paired.decodeJsonBody())
        .sessionAccessToken;
    final ReceivedControlResponse created = await client.send(
      _createRequest(sessionToken),
    );
    _record('CREATE_STATUS=${created.status}');
    expect(
      created.status,
      201,
      reason: 'body: ${utf8.decode(created.body, allowMalformed: true)}',
    );
    expect(created.decodeJsonBody()['state'], 'STAGING');

    client.close();
  });

  test('a wrong pin is refused on Android too, before any request', () async {
    final PairingPayload payload = PairingPayload.parse(_qrJson);
    final PairingCandidate candidate = payload.candidates.first;

    // One hex character changed: the same shape as a real pin, and definitely not it.
    final String wrongPin =
        (payload.serverFingerprint.startsWith('0') ? '1' : '0') +
        payload.serverFingerprint.substring(1);

    final List<String> presentations = <String>[];
    final HttpsControlClient client = HttpsControlClient(
      pin: wrongPin,
      host: _host,
      port: candidate.port,
      onCertificateSeen: (PinnedConnectionOutcome outcome, String presented) {
        presentations.add(presented);
        _record('WRONG_PIN_CERT_SEEN=${outcome.name} $presented');
      },
    );

    await expectLater(
      client.send(_pairRequest(payload)),
      throwsA(isA<ProtocolViolation>()),
    );
    _record('WRONG_PIN_PRESENTATIONS=${presentations.length}');

    expect(
      presentations,
      isNotEmpty,
      reason: 'the callback must have been consulted before the connection was refused',
    );
    expect(
      presentations.single,
      payload.serverFingerprint,
      reason:
          'Android saw the real certificate; only our comparison rejected it',
    );

    client.close();
  });
}

ControlRequest _pairRequest(PairingPayload payload) => ControlRequest(
  method: HttpMethod.post,
  target: '/v1/pair',
  headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
  body: Uint8List.fromList(
    utf8.encode(
      jsonEncode(
        PairRequest(
          requestId: randomUuidV4(),
          sessionId: payload.sessionId,
          pairToken: payload.pairToken,
          clientLabel: 'android integration test',
        ).toJson(),
      ),
    ),
  ),
);

ControlRequest _createRequest(String sessionToken) => ControlRequest(
  method: HttpMethod.post,
  target: '/v1/transfers',
  headers: <String, String>{
    'authorization': 'Bearer $sessionToken',
    'content-type': 'application/json; charset=utf-8',
  },
  body: Uint8List.fromList(
    utf8.encode(
      jsonEncode(<String, Object?>{
        'requestId': randomUuidV4(),
        'transferId': randomUuidV4(),
        'manifestDigest':
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        'fileCount': 1,
        'totalBytes': '4096',
        'direction': 'client_to_server',
      }),
    ),
  ),
);
