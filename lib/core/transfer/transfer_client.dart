/// The client half of a transfer: §3's pairing and §7's calls, over a pinned connection.
///
/// ## Why this is a separate class from [TransferEngine]
///
/// The engine answers "what does this node do with its own files and rows". This answers "what
/// does a peer ask the other end to do", and the two are deliberately apart because the roles
/// swap: in `client_to_server` the client is the sender and in `server_to_client` it is the
/// receiver, so the same client drives both directions and only the call order changes.
///
/// ## What it must not do
///
/// * It never invents a fact. The chunk lengths and digests it enforces come from the **frozen
///   manifest the peer served**, never from a response header, which §8 makes advisory.
/// * It never treats a download as persistence. §7: "下载成功不代表接收端持久化" - a chunk it
///   fetched is written and committed through §8's write order before it counts, and that is the
///   engine's job, not this one's.
/// * It never skips the pin. The pin is a constructor argument of the underlying
///   [HttpsControlClient] and no response can change it.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:nearsend/core/network/control_message.dart';
import 'package:nearsend/core/network/https_control_client.dart';
import 'package:nearsend/core/protocol/api_responses.dart';
import 'package:nearsend/core/protocol/api_routes.dart';
import 'package:nearsend/core/protocol/chunk_manifest.dart';
import 'package:nearsend/core/protocol/manifest.dart';
import 'package:nearsend/core/protocol/manifest_page.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/transfer_resume_request.dart';
import 'package:nearsend/core/security/pair_request.dart';
import 'package:nearsend/core/security/pairing_service.dart';
import 'package:nearsend/core/security/pairing_payload.dart';

/// A paired client of one node.
class TransferClient {
  TransferClient({
    required this.pin,
    required this.host,
    required this.port,
    this.onCertificateSeen,
  }) : _client = HttpsControlClient(
         pin: pin,
         host: host,
         port: port,
         onCertificateSeen: onCertificateSeen,
       );

  /// The pin from §3's payload: `SHA-256(server leaf DER)`.
  final String pin;
  final String host;
  final int port;

  /// Diagnostics hook, so a device test can assert the fingerprint it actually saw.
  final void Function(PinnedConnectionOutcome, String)? onCertificateSeen;

  final HttpsControlClient _client;

  String? _sessionToken;
  String? _taskAccessToken;

  String? get sessionToken => _sessionToken;
  String? get taskAccessToken => _taskAccessToken;

  /// Pairs using §3's payload, keeping the session token.
  ///
  /// The payload is the *only* trust input: the pin comes from it, and it is what the handshake
  /// is checked against before this method can send anything.
  Future<void> pairFrom(
    PairingPayload payload, {
    required String clientLabel,
  }) async {
    final PairRequest request = PairRequest(
      requestId: newUuid(),
      sessionId: payload.sessionId,
      pairToken: payload.pairToken,
      clientLabel: clientLabel,
    );
    final ReceivedControlResponse response = await _send(
      method: HttpMethod.post,
      target: '/v1/pair',
      body: request.toJson(),
      overrideToken: null,
    );
    if (!response.isSuccess) {
      throw ProtocolViolation(
        response.decodeError().code,
        'pairing was refused',
      );
    }
    final Object? token = response.decodeJsonBody()['sessionAccessToken'];
    if (token is! String) {
      throw const ProtocolViolation(
        ProtocolErrorCode.pairRejected,
        'the pairing response carried no session token',
      );
    }
    _sessionToken = token;
  }

  /// `POST /v1/transfers` - a client may only propose `client_to_server` (§7).
  Future<String> createTransfer({
    required String transferId,
    required String manifestDigest,
    required int fileCount,
    required int totalBytes,
  }) async {
    final ReceivedControlResponse response = await _send(
      method: HttpMethod.post,
      target: '/v1/transfers',
      body: <String, Object?>{
        'requestId': newUuid(),
        'transferId': transferId,
        'manifestDigest': manifestDigest,
        'fileCount': fileCount,
        'totalBytes': '$totalBytes',
        'direction': 'client_to_server',
      },
    );
    _assertSuccess(response, 'create the transfer');
    return transferId;
  }

  /// `PUT` every page of [manifest], which §6 requires before a seal.
  Future<void> uploadManifest({
    required String transferId,
    required FrozenManifest manifest,
    required List<ManifestPage> pages,
  }) async {
    for (final ManifestPage page in pages) {
      final ReceivedControlResponse response = await _send(
        method: HttpMethod.put,
        target: '/v1/transfers/$transferId/manifest',
        body: page.toJson(),
      );
      _assertSuccess(response, 'upload a manifest page');
    }
  }

  /// `POST /v1/transfers/{id}/seal`.
  Future<void> seal({
    required String transferId,
    required String manifestDigest,
  }) async {
    final ReceivedControlResponse response = await _send(
      method: HttpMethod.post,
      target: '/v1/transfers/$transferId/seal',
      body: <String, Object?>{
        'requestId': newUuid(),
        'manifestDigest': manifestDigest,
      },
    );
    _assertSuccess(response, 'seal the manifest');
  }

  /// `GET /v1/offers` - what this session is being offered (§6).
  Future<List<OfferSummary>> offers() async {
    final ReceivedControlResponse response = await _send(
      method: HttpMethod.get,
      target: '/v1/offers',
    );
    _assertSuccess(response, 'list offers');
    return OffersPage.parse(response.decodeJsonBody()).offers;
  }

  /// `POST /v1/transfers/{id}/decision`.
  Future<void> decide({
    required String transferId,
    required String manifestDigest,
    required bool accept,
  }) async {
    final ReceivedControlResponse response = await _send(
      method: HttpMethod.post,
      target: '/v1/transfers/$transferId/decision',
      body: <String, Object?>{
        'requestId': newUuid(),
        'manifestDigest': manifestDigest,
        'decision': accept ? 'accept' : 'reject',
      },
    );
    _assertSuccess(response, 'decide the transfer');
  }

  /// `GET /v1/transfers/{id}/authorization`, then the receipt §3 wants.
  ///
  /// The receipt is sent immediately because the secrets are being handed to this process and
  /// there is nowhere safer for them yet; §3 makes the receipt the client's statement that it
  /// stored them.
  Future<AuthorizationGrant> fetchAuthorization({
    required String transferId,
  }) async {
    final ReceivedControlResponse response = await _send(
      method: HttpMethod.get,
      target: '/v1/transfers/$transferId/authorization',
      overrideToken: _sessionToken,
    );
    _assertSuccess(response, 'fetch the authorisation grant');
    final AuthorizationGrant grant = AuthorizationGrant.parse(
      response.decodeJsonBody(),
    );

    final ReceivedControlResponse receipt = await _send(
      method: HttpMethod.post,
      target: '/v1/transfers/$transferId/authorization/receipt',
      body: <String, Object?>{'requestId': newUuid()},
      overrideToken: _sessionToken,
    );
    _assertSuccess(receipt, 'confirm the authorisation receipt');
    return grant;
  }

  /// `POST /v1/transfers/{id}/resume`, keeping the task access token.
  Future<ResumeGranted> resume({
    required String transferId,
    required String manifestDigest,
    required String taskResumeSecret,
    ReceiverState? receiverState,
  }) async {
    final ReceivedControlResponse response = await _send(
      method: HttpMethod.post,
      target: '/v1/transfers/$transferId/resume',
      body: <String, Object?>{
        'requestId': newUuid(),
        'manifestDigest': manifestDigest,
        'taskResumeSecret': taskResumeSecret,
        'receiverState': ?receiverState?.toJson(),
      },
      overrideToken: null,
    );
    _assertSuccess(response, 'resume the transfer');
    final ResumeGranted granted = ResumeGranted.parse(
      response.decodeJsonBody(),
    );
    _taskAccessToken = granted.taskAccessToken;
    return granted;
  }

  /// Reads the frozen manifest the peer sealed, pages and all.
  ///
  /// Both page kinds are needed: the file entries carry §5.2's sizes and digests, and the chunk
  /// pages carry §5.3's per-chunk digests. Reading only the first would leave the receiver unable
  /// to check a chunk against anything.
  Future<FrozenManifest> readManifest(String transferId) async {
    final List<ManifestFile> files = <ManifestFile>[];
    int start = 0;
    Map<String, Object?>? filePage;
    do {
      final ReceivedControlResponse response = await _send(
        method: HttpMethod.get,
        target:
            '/v1/transfers/$transferId/manifest?kind=files&startIndex=$start&limit=128',
      );
      _assertSuccess(response, 'read a file page');
      filePage = response.decodeJsonBody();
      // §7 adds `nextIndex` to §6's page body, so the page is parsed from a copy without it
      // while the field itself is read from the original response.
      final ManifestFilePage page =
          ManifestPage.parse(_withoutNextIndex(filePage)) as ManifestFilePage;
      files.addAll(page.items);
      final int? next = ApiResponses.nextIndex(filePage, page);
      if (next == null) {
        break;
      }
      start = next;
    } while (true);

    return FrozenManifest(
      protocolMajor: 1,
      protocolMinor: 0,
      transferId: transferId,
      files: files.isEmpty
          ? <ManifestFile>[
              // A manifest with no files is not a legal transfer, but `FrozenManifest` refuses an
              // empty list; reaching here means the peer served an impossible manifest, which the
              // caller must see rather than have papered over.
              throw const ProtocolViolation(
                ProtocolErrorCode.manifestMismatch,
                'the peer served a manifest with no files',
              ),
            ]
          : files,
    );
  }

  /// Reads one file's chunk records from the peer's chunk pages.
  Future<List<ChunkRecord>> readChunkRecords({
    required String transferId,
    required ManifestFile file,
  }) async {
    final List<ChunkRecord> records = <ChunkRecord>[];
    int start = 0;
    while (true) {
      final ReceivedControlResponse response = await _send(
        method: HttpMethod.get,
        target:
            '/v1/transfers/$transferId/manifest?kind=chunks&fileId=${file.fileId}'
            '&startIndex=$start&limit=1024',
      );
      _assertSuccess(response, 'read a chunk page');
      final Map<String, Object?> body = response.decodeJsonBody();
      final ManifestChunkPage page =
          ManifestPage.parse(_withoutNextIndex(body)) as ManifestChunkPage;
      records.addAll(page.items);
      final int? next = ApiResponses.nextIndex(body, page);
      if (next == null) {
        break;
      }
      start = next;
    }
    if (records.length != file.chunkCount) {
      throw ProtocolViolation(
        ProtocolErrorCode.manifestMismatch,
        'the peer served ${records.length} chunk records for ${file.fileId} but its file '
        'entry declares ${file.chunkCount}',
      );
    }
    return records;
  }

  /// `PUT` one chunk (§8), returning the peer's answer.
  Future<ChunkWriteResult> putChunk({
    required String transferId,
    required String fileId,
    required int index,
    required Uint8List bytes,
    required int leaseEpoch,
    required String manifestDigest,
  }) async {
    final ReceivedControlResponse response = await _send(
      method: HttpMethod.put,
      target: '/v1/transfers/$transferId/files/$fileId/chunks/$index',
      rawBody: bytes,
      headers: <String, String>{
        'authorization': 'Bearer $_taskAccessToken',
        'content-type': 'application/octet-stream',
        'content-length': '${bytes.length}',
        'x-lft-lease-epoch': '$leaseEpoch',
        'x-lft-manifest-digest': manifestDigest,
      },
    );
    _assertSuccess(response, 'put a chunk');
    return ChunkWriteResult.parse(response.decodeJsonBody());
  }

  /// `GET` one chunk (§8). The bytes are the peer's answer; nothing here trusts them.
  Future<Uint8List> getChunk({
    required String transferId,
    required String fileId,
    required int index,
    required int leaseEpoch,
    required String manifestDigest,
  }) async {
    final ReceivedControlResponse response = await _send(
      method: HttpMethod.get,
      target: '/v1/transfers/$transferId/files/$fileId/chunks/$index',
      headers: <String, String>{
        'authorization': 'Bearer $_taskAccessToken',
        'x-lft-lease-epoch': '$leaseEpoch',
        'x-lft-manifest-digest': manifestDigest,
      },
    );
    _assertSuccess(response, 'get a chunk');
    return response.body;
  }

  /// `POST /v1/transfers/{id}/checkpoint` - a client receiver's report (§9).
  Future<void> reportCheckpoint({
    required String transferId,
    required String manifestDigest,
    required int leaseEpoch,
    required int checkpointSeq,
    required int committedBytes,
  }) async {
    final ReceivedControlResponse response = await _send(
      method: HttpMethod.post,
      target: '/v1/transfers/$transferId/checkpoint',
      body: <String, Object?>{
        'requestId': newUuid(),
        'manifestDigest': manifestDigest,
        'leaseEpoch': '$leaseEpoch',
        'checkpointSeq': '$checkpointSeq',
        'committedBytes': '$committedBytes',
      },
    );
    _assertSuccess(response, 'report the checkpoint');
  }

  /// `POST /v1/transfers/{id}/complete` (§10).
  Future<void> complete({
    required String transferId,
    required String fileId,
    required int leaseEpoch,
    required bool saved,
    String? fileSha256,
  }) async {
    final ReceivedControlResponse response = await _send(
      method: HttpMethod.post,
      target: '/v1/transfers/$transferId/complete',
      body: <String, Object?>{
        'requestId': newUuid(),
        'leaseEpoch': '$leaseEpoch',
        'fileId': fileId,
        'result': saved ? 'saved' : 'request_verify',
        'fileSha256': ?fileSha256,
      },
    );
    _assertSuccess(response, 'complete the file');
  }

  void close() => _client.close();

  /// Sends one request, choosing the credential the call needs.
  ///
  /// [overrideToken] is explicit rather than "use the session if present" because §7 gives
  /// different routes different credentials: the chunk routes need the *task* token, and sending
  /// a session token there would be refused - correctly, and confusingly.
  Future<ReceivedControlResponse> _send({
    required HttpMethod method,
    required String target,
    Map<String, Object?>? body,
    Uint8List? rawBody,
    Map<String, String>? headers,
    Object? overrideToken = _unset,
  }) {
    final String? token = overrideToken == _unset
        ? _taskAccessToken ?? _sessionToken
        : overrideToken as String?;
    final Map<String, String> resolved = <String, String>{
      ...?headers,
      if (headers == null || !headers.containsKey('authorization'))
        'authorization': ?(token == null ? null : 'Bearer $token'),
    };
    final Uint8List? encoded =
        rawBody ??
        (body == null
            ? null
            : Uint8List.fromList(utf8.encode(jsonEncode(body))));
    return _client.send(
      ControlRequest(
        method: method,
        target: target,
        headers: resolved,
        body: encoded,
      ),
    );
  }

  static void _assertSuccess(ReceivedControlResponse response, String what) {
    if (response.isSuccess) {
      return;
    }
    throw ProtocolViolation(
      response.decodeError().code,
      'the peer refused to $what (${response.status})',
    );
  }
}

/// A copy of a page response with §7's `nextIndex` removed.
///
/// `nextIndex` belongs to the response rather than to §6's page, and `ManifestPage.parse`
/// refuses an undefined field - so the page is parsed from the body without it, while the field
/// itself is still read from the original.
Map<String, Object?> _withoutNextIndex(Map<String, Object?> body) {
  final Map<String, Object?> copy = Map<String, Object?>.of(body);
  copy.remove(ApiResponses.nextIndexField);
  return copy;
}

/// Sentinel so "no credential" and "the caller did not say" are different.
const Object _unset = Object();

/// A fresh canonical UUID, for §9's `requestId`.
///
/// Built here rather than imported from the pairing layer so this file has one dependency on the
/// protocol's identifier shape instead of two.
String newUuid() => randomUuidV4();
