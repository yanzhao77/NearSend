/// The connection to a peer, as a state a screen can watch.
///
/// ## What it adds to [TransferClient]
///
/// [TransferClient] knows how to pair with **one** address and what to do afterwards. A pairing
/// payload carries a list of them (§3), because a device with two interfaces publishes two, and
/// which one answers is not knowable in advance. So somebody has to try them in order, decide when
/// to stop, and - the part that matters - say *why* the connection failed, because "could not
/// connect" and "the peer's certificate is not the one the code named" are the same event to a
/// socket and completely different events to a user.
///
/// ## The rule it must not break
///
/// §2 makes the fingerprint in the payload the whole of the trust decision, and §3 says choosing a
/// candidate must not be able to bypass it. Here that is structural: the pin is taken from the
/// payload and handed to the client, and **no candidate is retried after a fingerprint mismatch** -
/// a mismatch is a statement about the peer's identity, not about that address, so trying the
/// second address would only be asking the same question twice.
///
/// A wrong pin never reaches the server at all: the client's certificate callback refuses the
/// connection before any request, which is what `sawAnyCertificate` and the mismatch reading below
/// exist to show rather than assume.
library;

import 'package:flutter/foundation.dart';

import 'package:nearsend/core/network/https_control_client.dart';
import 'package:nearsend/core/security/pairing_payload.dart';
import 'package:nearsend/core/transfer/transfer_client.dart';

/// Where a connection attempt is.
enum PeerPhase {
  /// Not connected and not trying.
  idle,

  /// Trying the payload's addresses.
  connecting,

  /// Paired: the peer proved the identity the payload named.
  connected,

  /// Refused. [PeerSession.failureReason] says why.
  failed,
}

/// Opens a client for one candidate address.
///
/// A typedef so a test can state its own client, which is what makes the mismatch path testable
/// without a second device.
typedef TransferClientFactory = TransferClient Function({
  required String pin,
  required String host,
  required int port,
  void Function(PinnedConnectionOutcome, String)? onCertificateSeen,
});

/// Owns the paired connection to one peer.
class PeerSession extends ChangeNotifier {
  PeerSession({
    this.clientLabel = 'NearSend',
    this.connectTimeout = const Duration(seconds: 10),
    TransferClientFactory? openClient,
  }) : _openClient =
           openClient ??
           (({
             required String pin,
             required String host,
             required int port,
             void Function(PinnedConnectionOutcome, String)? onCertificateSeen,
           }) => TransferClient(
             pin: pin,
             host: host,
             port: port,
             onCertificateSeen: onCertificateSeen,
           ));

  /// What this device calls itself in §3's handshake.
  final String clientLabel;

  /// How long one candidate address gets before the next is tried.
  ///
  /// A socket to a host that is not there can hang for the operating system's own timeout, which is
  /// minutes; a user watching a connection screen should not wait for it, and a payload normally
  /// names a machine on the same link, where a working address answers in milliseconds.
  final Duration connectTimeout;

  final TransferClientFactory _openClient;

  /// Said when the peer's certificate is not the one the payload named (§2).
  static const String pinMismatchReason = '对方的证书指纹与连接信息不符，连接已中止。请重新配对，不要继续。';

  /// Said when no address answered.
  static const String unreachableReason =
      '无法连接到对方设备，请确认两台设备在同一 Wi-Fi 下并重新出示连接信息。';

  PeerPhase _phase = PeerPhase.idle;
  TransferClient? _client;
  PairingPayload? _peer;
  String? _failureReason;
  bool _pinMismatched = false;
  String? _presentedFingerprint;
  bool _disposed = false;

  PeerPhase get phase => _phase;

  bool get isConnected => _phase == PeerPhase.connected && _client != null;

  /// The paired client, or null when there is none.
  TransferClient? get client => _client;

  /// The payload this device paired against, which is the record of what was trusted.
  PairingPayload? get peer => _peer;

  String? get failureReason => _failureReason;

  /// Whether the refusal was a fingerprint mismatch rather than an unreachable peer.
  ///
  /// Separate from [failureReason] because the two need different words: an unreachable peer is
  /// worth retrying, and a mismatched fingerprint is not.
  bool get pinMismatched => _pinMismatched;

  /// The fingerprint the peer's certificate actually produced, when one was seen.
  ///
  /// Not a secret - it is the value the peer publishes in its own payload - and the only way a user
  /// can see that the two devices disagree about a certificate rather than merely that a connection
  /// failed.
  String? get presentedFingerprint => _presentedFingerprint;

  /// Pairs with the device that published [payload], trying its addresses in order.
  ///
  /// Returns whether a connection was established; the phase says the same thing, so a caller may
  /// use whichever reads better.
  Future<bool> connect(PairingPayload payload) async {
    if (_phase == PeerPhase.connecting) {
      return false;
    }
    _reset();
    _set(
      phase: PeerPhase.connecting,
      failureReason: null,
      pinMismatched: false,
      presentedFingerprint: null,
    );

    bool sawMismatch = false;
    String? presented;
    for (final PairingCandidate candidate in payload.candidates) {
      TransferClient? client;
      try {
        client = _openClient(
          pin: payload.serverFingerprint,
          host: candidate.host,
          port: candidate.port,
          onCertificateSeen:
              (PinnedConnectionOutcome outcome, String fingerprint) {
                if (outcome == PinnedConnectionOutcome.pinMismatched) {
                  sawMismatch = true;
                  presented = fingerprint;
                }
              },
        );
        await client
            .pairFrom(payload, clientLabel: clientLabel)
            .timeout(connectTimeout);
        _client = client;
        _peer = payload;
        _set(phase: PeerPhase.connected, failureReason: null);
        return true;
      } on Object {
        client?.close();
        if (sawMismatch) {
          // §2: a mismatch is a statement about the peer's identity, not about this address, so
          // the remaining candidates are not tried. Retrying would be asking the same question of
          // the same identity and hoping for a different answer.
          break;
        }
      }
    }

    _set(
      phase: PeerPhase.failed,
      failureReason: sawMismatch ? pinMismatchReason : unreachableReason,
      pinMismatched: sawMismatch,
      presentedFingerprint: sawMismatch ? presented : null,
    );
    return false;
  }

  /// Drops the connection, if there is one.
  void disconnect() {
    _reset();
    _set(phase: PeerPhase.idle, failureReason: null);
  }

  @override
  void dispose() {
    _disposed = true;
    _reset();
    super.dispose();
  }

  void _reset() {
    _client?.close();
    _client = null;
    _peer = null;
  }

  void _set({
    required PeerPhase phase,
    required String? failureReason,
    bool pinMismatched = false,
    String? presentedFingerprint,
  }) {
    _phase = phase;
    _failureReason = failureReason;
    _pinMismatched = pinMismatched;
    _presentedFingerprint = presentedFingerprint;
    if (!_disposed) {
      notifyListeners();
    }
  }
}
