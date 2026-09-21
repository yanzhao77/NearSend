import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/core/storage/source_bytes.dart';
import 'package:nearsend/platform/android_file_gateway.dart';

/// The sender's byte source, and the two implementations of it.
///
/// The point of this port is that a path and a SAF document are interchangeable above it, so the
/// cases below run **the same expectations against both**: a chunk read at an offset returns what is
/// there, a read past the end returns less rather than a padded buffer, and a length nobody knows is
/// reported as unknown rather than guessed.
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('nearsend-source-');
  });

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  /// The expectations both implementations must satisfy.
  Future<void> sharedContract(
    SourceBytes source, {
    required Uint8List expected,
  }) async {
    expect(
      await source.length(),
      expected.length,
      reason: 'the length the sender declares must be the source real length',
    );

    expect(
      await source.readAt(offset: 0, length: 4),
      Uint8List.sublistView(expected, 0, 4),
      reason:
          'an offset-addressed read returns exactly the bytes at that offset',
    );

    expect(
      await source.readAt(offset: 4, length: ProtocolLimits.chunkSizeBytes),
      Uint8List.sublistView(expected, 4),
      reason:
          'a read longer than the remainder is short rather than padded - §5.3 fixes each chunk '
          'length, so padding would produce a chunk that fails its digest for no visible reason',
    );

    expect(
      await source.readAt(offset: expected.length, length: 4),
      isEmpty,
      reason:
          'a read entirely past the end returns nothing rather than throwing',
    );
  }

  test('a file source satisfies the contract', () async {
    final Uint8List body = Uint8List.fromList(
      List<int>.generate(9, (int i) => i * 5),
    );
    final File file = File('${root.path}${Platform.pathSeparator}payload.bin')
      ..writeAsBytesSync(body);

    await sharedContract(FileSourceBytes(file), expected: body);
  });

  test('a file source handles chunk-sized reads across a boundary', () async {
    // Two chunks plus a tail, which is the shape §8's tail rule and the file-end checkpoint turn on.
    final Uint8List body = Uint8List.fromList(
      List<int>.generate(ProtocolLimits.chunkSizeBytes + 3, (int i) => i % 251),
    );
    final File file = File('${root.path}${Platform.pathSeparator}big.bin')
      ..writeAsBytesSync(body);
    final SourceBytes source = FileSourceBytes(file);

    expect(
      await source.readAt(offset: 0, length: ProtocolLimits.chunkSizeBytes),
      Uint8List.sublistView(body, 0, ProtocolLimits.chunkSizeBytes),
    );
    expect(
      await source.readAt(
        offset: ProtocolLimits.chunkSizeBytes,
        length: ProtocolLimits.chunkSizeBytes,
      ),
      Uint8List.sublistView(body, ProtocolLimits.chunkSizeBytes),
      reason: 'the tail is three bytes and is returned as three, not four MiB',
    );
  });

  test(
    'a SAF source satisfies the contract through the channel port',
    () async {
      final Uint8List body = Uint8List.fromList(
        List<int>.generate(9, (int i) => i * 5),
      );
      final InMemoryFileGateway gateway = InMemoryFileGateway(
        documents: <String, Uint8List>{'content://provider/a': body},
      );

      await sharedContract(
        SafSourceBytes(
          gateway: gateway,
          uri: 'content://provider/a',
          providerReportedSize: body.length,
        ),
        expected: body,
      );
    },
  );

  test('a SAF source reads one bounded chunk at a time', () async {
    final Uint8List body = Uint8List.fromList(
      List<int>.generate(ProtocolLimits.chunkSizeBytes + 3, (int i) => i % 97),
    );
    final InMemoryFileGateway gateway = InMemoryFileGateway(
      documents: <String, Uint8List>{'content://provider/big': body},
    );
    final SourceBytes source = SafSourceBytes(
      gateway: gateway,
      uri: 'content://provider/big',
      providerReportedSize: body.length,
    );

    final Uint8List first = await source.readAt(
      offset: 0,
      length: ProtocolLimits.chunkSizeBytes,
    );
    final Uint8List tail = await source.readAt(
      offset: ProtocolLimits.chunkSizeBytes,
      length: ProtocolLimits.chunkSizeBytes,
    );

    expect(first.length, ProtocolLimits.chunkSizeBytes);
    expect(tail.length, 3);
    expect(
      <int>[...first, ...tail],
      body,
      reason: 'the two reads reassemble the document exactly',
    );
  });

  test(
    'a size the provider withheld stays unknown instead of becoming zero',
    () async {
      final SafSourceBytes source = SafSourceBytes(
        gateway: InMemoryFileGateway(),
        uri: 'content://provider/quiet',
        providerReportedSize: null,
      );

      await expectLater(
        source.length(),
        throwsA(isA<PlatformFileFailure>()),
        reason:
            '§5.2 hashes the real size into the manifest, so a guessed length would build a '
            'manifest for a different file and the receiver would verify against it - failing '
            'loudly is the only honest answer',
      );
    },
  );

  test('a diagnostic label never reveals a path or a URI', () async {
    final SourceBytes file = FileSourceBytes(
      File('${root.path}${Platform.pathSeparator}secret-name.bin'),
    );
    final SourceBytes saf = SafSourceBytes(
      gateway: InMemoryFileGateway(),
      uri: 'content://provider/secret-document-id',
      providerReportedSize: 1,
    );

    expect(file.diagnosticLabel, 'file');
    expect(saf.diagnosticLabel, 'saf');
    expect(
      saf.diagnosticLabel,
      isNot(contains('secret')),
      reason: 'AGENTS.md §5 keeps user file locations out of diagnostics, and a document id is one',
    );
  });
}
