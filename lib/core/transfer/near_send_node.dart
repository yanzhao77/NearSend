/// One NearSend node: the database, the endpoints, the TLS server and the local engine.
///
/// ## Why an assembly class exists
///
/// Every stage of §7's pipeline was implemented and tested in isolation, and each endpoint takes
/// the repositories it needs. Nothing built the object graph, which meant nothing could actually
/// run: the pipeline's handler map was empty in every test that exercised it, and no run had ever
/// put a `pair` response's token into a `transfers` request over a real socket.
///
/// This file is that object graph, in one place, so the two ends of a transfer are the same code
/// with different roles rather than two implementations that drift.
///
/// ## §7's pipeline, as assembled here
///
/// | stage | where |
/// | --- | --- |
/// | TLS + pin | `HttpsControlServer` terminates TLS at 1.3; a client pins via `HttpsControlClient` |
/// | 会话身份 / token | [ChainedAuthenticator]: §3's session tokens, then §7's task tokens |
/// | 任务授权 | `ControlAuthorizer`, with [SqliteTaskOwnership] answering §7's session-scoped rows |
/// | 参数验证 | `ApiRoutes.match` (unchanged, already before authorisation) |
/// | 用例 | the handler map built here |
/// | 结构化错误 | `ControlResponse.error` via `WireError` |
///
/// `request_id` idempotency is applied *inside* each use case, because §9's scope needs the
/// request's own credential and the endpoint is what knows the operation name.
///
/// ## What is deliberately not here
///
/// No QR image rendering and no mDNS: §3 makes the QR payload the authoritative first-trust
/// source and this node publishes it, but turning it into a picture is a UI concern. No
/// capability vocabulary: §3's `capabilities` list was never defined, so this node announces an
/// empty set and does not negotiate (`AGENTS.md` §3 forbids inventing the words).
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:nearsend/core/network/chunk_transfer_endpoint.dart';
import 'package:nearsend/core/network/control_authorization.dart';
import 'package:nearsend/core/network/control_message.dart';
import 'package:nearsend/core/network/control_pipeline.dart';
import 'package:nearsend/core/network/https_control_server.dart';
import 'package:nearsend/core/network/manifest_staging_registry.dart';
import 'package:nearsend/core/network/task_authorization_endpoint.dart';
import 'package:nearsend/core/network/task_ownership.dart';
import 'package:nearsend/core/network/task_token_authenticator.dart';
import 'package:nearsend/core/network/transfer_creation_handler.dart';
import 'package:nearsend/core/network/transfer_lifecycle_endpoint.dart';
import 'package:nearsend/core/network/transfer_staging_endpoint.dart';
import 'package:nearsend/core/protocol/api_routes.dart';
import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/security/pairing_payload.dart';
import 'package:nearsend/core/security/pairing_service.dart';
import 'package:nearsend/core/security/tls_identity.dart';
import 'package:nearsend/core/storage/chunk_repository.dart';
import 'package:nearsend/core/storage/export_service.dart';
import 'package:nearsend/core/storage/file_verification.dart';
import 'package:nearsend/core/storage/idempotency_repository.dart';
import 'package:nearsend/core/storage/local_file_layer.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/receiver_mirror_repository.dart';
import 'package:nearsend/core/storage/storage_failure.dart';
import 'package:nearsend/core/storage/task_authorization_repository.dart';
import 'package:nearsend/core/storage/task_credential_repository.dart';
import 'package:nearsend/core/storage/task_source_repository.dart';
import 'package:nearsend/core/storage/transfer_repository.dart';
import 'package:nearsend/core/transfer/transfer_engine.dart';

/// Reads an outbound chunk from the file this node recorded as a task's source.
///
/// The port exists because a desktop path and a SAF URI are not the same thing; this
/// implementation covers the path case, which is what a Windows sender and an app-private
/// Android sender both have.
class TaskFileChunkSource implements OutgoingChunkSource {
  TaskFileChunkSource(this.sources);

  final TaskSourceRepository sources;

  @override
  Future<Uint8List> readChunk({
    required String transferId,
    required String fileId,
    required int offsetBytes,
    required int length,
  }) async {
    final TaskSourceRecord? record = sources.read(transferId, fileId);
    if (record == null) {
      throw StorageException(
        StorageFailureCode.manifestMismatch,
        'no source is recorded for $fileId',
      );
    }
    final File file = File(record.sourceRef);
    if (!file.existsSync()) {
      // §11 pairs SOURCE_CHANGED with "repair from the correct source"; a source that is gone is
      // exactly that, and serving zeros instead would look like a successful transfer.
      throw const ProtocolViolation(
        ProtocolErrorCode.sourceChanged,
        'the recorded source for this file is no longer readable',
      );
    }
    if (await file.length() != record.sizeBytes) {
      throw const ProtocolViolation(
        ProtocolErrorCode.sourceChanged,
        'the source changed size since the task was created',
      );
    }
    final RandomAccessFile handle = await file.open();
    try {
      await handle.setPosition(offsetBytes);
      final Uint8List buffer = Uint8List(length);
      int filled = 0;
      while (filled < length) {
        final int read = await handle.readInto(buffer, filled, length - filled);
        if (read <= 0) {
          break;
        }
        filled += read;
      }
      if (filled != length) {
        throw const ProtocolViolation(
          ProtocolErrorCode.sourceChanged,
          'the source ended before the chunk did',
        );
      }
      return buffer;
    } finally {
      await handle.close();
    }
  }
}

/// A running node: its own database, identity, endpoints and engine.
class NearSendNode {
  NearSendNode._({
    required this.directory,
    required this.database,
    required this.identity,
    required this.pairing,
    required this.transfers,
    required this.tasks,
    required this.staging,
    required this.authorizations,
    required this.credentials,
    required this.sources,
    required this.ownership,
    required this.mirror,
    required this.windows,
    required this.layout,
    required this.sink,
    required this.reader,
    required this.engine,
    required this.pipeline,
    required this.chunkEndpoint,
    required this.lifecycle,
    required this.authorizationEndpoint,
    required this.stagingEndpoint,
    required this.creationEndpoint,
    required this.server,
  });

  final String directory;
  final NearSendDatabase database;
  final TlsIdentity identity;
  final PairingService pairing;
  final TransferRepository transfers;
  final ChunkRepository tasks;
  final ManifestStagingRegistry staging;
  final TaskAuthorizationRepository authorizations;
  final TaskCredentialRepository credentials;
  final TaskSourceRepository sources;
  final SqliteTaskOwnership ownership;
  final ReceiverMirrorRepository mirror;
  final ChunkWindowRegistry windows;
  final LocalStagingLayout layout;
  final StagingFileSink sink;
  final StagingChunkReader reader;
  final TransferEngine engine;
  final ControlPipeline pipeline;
  final ChunkTransferEndpoint chunkEndpoint;
  final TransferLifecycleEndpoint lifecycle;
  final TaskAuthorizationEndpoint authorizationEndpoint;
  final TransferStagingEndpoint stagingEndpoint;
  final TransferCreationEndpoint creationEndpoint;
  final HttpsControlServer server;

  /// The pin a client must compare against: `SHA-256(leaf certificate DER)` (§2).
  String get pin => identity.pin;

  /// The most recently issued pairing payload, or null before [openPairingSession].
  ///
  /// Held here rather than asked of the pairing service because §3 makes the payload a
  /// *published* artefact: what the QR code shows is what this node last issued, and a second
  /// session replaces it.
  PairingPayload? get payload => _payload;
  PairingPayload? _payload;

  /// Opens a pairing session and returns the payload the QR code should carry (§3).
  ///
  /// Re-issuing invalidates the previous session's access token, which §3 requires: a screenshot
  /// of the old code must stop working the moment a new one exists.
  PairingPayload openPairingSession({String? sessionId}) {
    final PairingPayload issued = pairing.openSession(sessionId: sessionId);
    _payload = issued;
    return issued;
  }

  /// Opens a node rooted at [directory], which holds its database and its staging.
  ///
  /// [candidateAddresses] become the certificate's SANs and the QR code's candidates; they are
  /// the addresses a peer is expected to reach this node by, and §3 requires choosing one not to
  /// be able to bypass the pin - which it cannot, because the pin travels in the payload.
  static Future<NearSendNode> open({
    required String directory,
    required List<String> candidateAddresses,
    int port = 0,
    String commonName = 'NearSend',
  }) async {
    final Directory root = Directory(directory);
    if (!root.existsSync()) {
      await root.create(recursive: true);
    }

    final TlsIdentity identity = generateTlsIdentity(
      commonName: commonName,
      subjectAltNames: candidateAddresses,
    );

    final NearSendDatabase database = NearSendDatabase.open(
      path: '${root.path}${Platform.pathSeparator}nearsend.db',
    );

    final TransferRepository transfers = TransferRepository(database);
    final ChunkRepository tasks = ChunkRepository(database);
    final ManifestStagingRegistry staging = ManifestStagingRegistry(
      transfers: transfers,
    );
    final TaskAuthorizationRepository authorizations =
        TaskAuthorizationRepository(database);
    final TaskCredentialRepository credentials = TaskCredentialRepository(
      database,
    );
    final TaskSourceRepository sources = TaskSourceRepository(database);
    final SqliteTaskOwnership ownership = SqliteTaskOwnership(database);
    final ReceiverMirrorRepository mirror = ReceiverMirrorRepository(database);
    final ChunkWindowRegistry windows = ChunkWindowRegistry(tasks: tasks);
    final LocalStagingLayout layout = LocalStagingLayout(
      Directory('${root.path}${Platform.pathSeparator}staging-root'),
    );
    await layout.prepare();
    final StagingFileSink sink = StagingFileSink(layout);
    final StagingChunkReader reader = StagingChunkReader(layout);

    final PairingService pairing = PairingService(
      serverFingerprint: identity.pin,
      candidates: <PairingCandidate>[
        for (final String address in candidateAddresses)
          PairingCandidate(host: address, port: port),
      ],
    );

    final TransferEngine engine = TransferEngine(
      database: database,
      transfers: transfers,
      tasks: tasks,
      staging: staging,
      authorizations: authorizations,
      credentials: credentials,
      sources: sources,
      ownership: ownership,
      layout: layout,
      sink: sink,
      reader: reader,
      verifier: FileVerifier(database, reader: reader, chunks: tasks),
      exporter: ExportService(
        database: database,
        sink: LocalDirectoryExportSink(layout: layout, staging: sink),
        transfers: transfers,
      ),
      windows: windows,
    );

    final ChunkTransferEndpoint chunkEndpoint = ChunkTransferEndpoint(
      tasks: tasks,
      staging: staging,
      windows: windows,
      sink: sink,
      source: TaskFileChunkSource(sources),
    );

    final TransferStagingEndpoint stagingEndpoint = TransferStagingEndpoint(
      idempotency: IdempotencyRepository(database),
      transfers: transfers,
      staging: staging,
    );

    final TransferCreationEndpoint creationEndpoint = TransferCreationEndpoint(
      idempotency: IdempotencyRepository(database),
      transfers: transfers,
      tasks: tasks,
    );

    final TransferLifecycleEndpoint lifecycle = TransferLifecycleEndpoint(
      idempotency: IdempotencyRepository(database),
      transfers: transfers,
      tasks: tasks,
      staging: staging,
      mirror: mirror,
      ownership: ownership,
      windows: windows,
      revokeCredentials: credentials.revokeAll,
      // §10 makes the server's final check local work; the engine is what runs it, so the
      // endpoint only has to say the task is now VERIFYING.
      onVerificationRequested: (String _, String _) {},
    );

    final TaskAuthorizationEndpoint authorizationEndpoint =
        TaskAuthorizationEndpoint(
          idempotency: IdempotencyRepository(database),
          transfers: transfers,
          tasks: tasks,
          staging: staging,
          authorizations: authorizations,
          credentials: credentials,
          mirror: mirror,
          receiverContext: null,
        );

    // §3's session tokens and §7's task tokens both arrive as `Authorization: Bearer`, so the
    // pipeline needs one authenticator that knows both. Ordering is not a security decision:
    // the two are 256-bit values from independent stores, so no token satisfies both.
    final ControlAuthenticator authenticator = ChainedAuthenticator(
      <ControlAuthenticator>[
        pairing,
        TaskTokenAuthenticator(credentials: credentials, transfers: transfers),
      ],
    );

    final Map<String, ControlHandler> handlers = <String, ControlHandler>{
      ...pairing.handlers(),
      ...stagingEndpoint.handlers(),
      ...authorizationEndpoint.handlers(),
      ...chunkEndpoint.handlers(),
      ...lifecycle.handlers(),
      // §7's creation row is the one whose use case is a method rather than a handler map, so it
      // is wrapped here. The wrapper is also where §7's session-to-task binding is recorded: the
      // session that proposed the transfer is the peer entitled to reach its later rows, and
      // without this the manifest upload - which is transfer-scoped - could not be authorised.
      ApiRoutes.createTransfer.name:
          (
            ControlRequest request,
            MatchedApiRequest matched,
            ControlAuthorized authorization,
          ) async {
            final ControlResponse response = await creationEndpoint.handler(
              request,
              matched,
              authorization,
            );
            final ControlGrant? grant = authorization.grant;
            if (response.status == 201 && grant is SessionGrant) {
              final Object? transferId = response
                  .decodeJsonBody()['transferId'];
              if (transferId is String) {
                ownership.assign(transferId, grant.peerId);
              }
            }
            return response;
          },
    };

    final ControlPipeline pipeline = ControlPipeline(
      authenticator: authenticator,
      handlers: handlers,
      ownership: ownership,
    );

    final HttpsControlServer server = HttpsControlServer(
      identity: identity,
      pipeline: pipeline,
      port: port,
    );

    return NearSendNode._(
      directory: directory,
      database: database,
      identity: identity,
      pairing: pairing,
      transfers: transfers,
      tasks: tasks,
      staging: staging,
      authorizations: authorizations,
      credentials: credentials,
      sources: sources,
      ownership: ownership,
      mirror: mirror,
      windows: windows,
      layout: layout,
      sink: sink,
      reader: reader,
      engine: engine,
      pipeline: pipeline,
      chunkEndpoint: chunkEndpoint,
      lifecycle: lifecycle,
      authorizationEndpoint: authorizationEndpoint,
      stagingEndpoint: stagingEndpoint,
      creationEndpoint: creationEndpoint,
      server: server,
    );
  }

  /// Starts listening. [port] is the constructor's value; `0` asks the system for a free one.
  Future<void> start() async {
    // The QR payload is issued by the caller through [openPairingSession] *after* this returns,
    // because a candidate carries a port and a payload built before the socket bound would offer
    // a port nothing is listening on.
    await server.start();
  }

  Future<void> stop() => server.stop();

  void close() {
    database.close();
  }
}
