import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/protocol/protocol_limits.dart';
import 'package:nearsend/platform/android_file_gateway.dart';

/// The Android file-access channel, from the Dart side.
///
/// The Kotlin half cannot run here, so what these cases pin down is the **contract between the two
/// halves** - which is where the two ways this can go quietly wrong live: a provider that will not
/// report a size must not be read as an empty file, and a read must be bounded by the length the
/// caller asked for rather than by the file.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel(
    MethodChannelAndroidFileGateway.channelName,
  );

  late List<MethodCall> calls;
  late MethodChannelAndroidFileGateway gateway;

  void answer(String method, Object? Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          if (call.method == method) {
            return handler(call);
          }
          return null;
        });
  }

  setUp(() {
    calls = <MethodCall>[];
    gateway = MethodChannelAndroidFileGateway();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('a picked document carries its uri, name and size', () async {
    answer('pickFiles', (MethodCall _) {
      return <Map<String, Object?>>[
        <String, Object?>{
          'uri': 'content://provider/1',
          'name': '鎶ュ憡.bin',
          'sizeBytes': 4096,
        },
      ];
    });

    final List<PickedDocument> picked = await gateway.pickFiles();
    expect(picked, hasLength(1));
    expect(picked.single.uri, 'content://provider/1');
    expect(picked.single.displayName, '鎶ュ憡.bin');
    expect(picked.single.sizeBytes, 4096);
  });

  test('a provider that reports no size becomes null, never zero', () async {
    answer('pickFiles', (MethodCall _) {
      return <Map<String, Object?>>[
        <String, Object?>{
          'uri': 'content://provider/2',
          'name': 'unknown.bin',
          // The channel's own convention for "the provider would not say".
          'sizeBytes': -1,
        },
      ];
    });

    final List<PickedDocument> picked = await gateway.pickFiles();
    expect(
      picked.single.sizeBytes,
      isNull,
      reason:
          '搂5.2 hashes the real size into the manifest, so a zero here would build a manifest '
          'for a file that does not exist, and the receiver would verify against it',
    );
  });

  test('a cancelled pick is an empty list, not an error', () async {
    answer('pickFiles', (MethodCall _) => <Object?>[]);
    expect(await gateway.pickFiles(), isEmpty);
  });

  test('a read asks for exactly the bounded length at the offset', () async {
    final Uint8List payload = Uint8List.fromList(
      List<int>.generate(64, (int i) => i),
    );
    answer('readChunk', (MethodCall call) {
      final Map<Object?, Object?> args = (call.arguments as Map)
          .cast<Object?, Object?>();
      final int offset = args['offset']! as int;
      final int length = args['length']! as int;
      expect(
        length,
        ProtocolLimits.chunkSizeBytes,
        reason: 'the request is one protocol chunk, which is what bounds the memory on both sides',
      );
      return Uint8List.sublistView(
        payload,
        offset,
        offset + length > payload.length ? payload.length : offset + length,
      );
    });

    final Uint8List bytes = await gateway.readChunk(
      uri: 'content://provider/1',
      offset: 0,
      length: ProtocolLimits.chunkSizeBytes,
    );
    expect(bytes, payload);
    expect(calls, hasLength(1));
  });

  test('a short read is reported short rather than padded', () async {
    answer('readChunk', (MethodCall _) => Uint8List.fromList(<int>[1, 2, 3]));

    final Uint8List bytes = await gateway.readChunk(
      uri: 'content://provider/1',
      offset: 0,
      length: 64,
    );
    expect(
      bytes.length,
      3,
      reason:
          '搂5.3 fixes each chunk length, so padding would produce a chunk that fails its digest '
          'with no explanation of why',
    );
  });

  test('the write sequence is begin, chunk, end', () async {
    answer('beginWrite', (MethodCall _) => true);
    answer('writeChunk', (MethodCall _) => 4);
    answer('endWrite', (MethodCall _) => true);

    await gateway.beginWrite(uri: 'content://provider/out');
    await gateway.writeChunk(
      uri: 'content://provider/out',
      offset: 0,
      bytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
    );
    await gateway.endWrite(uri: 'content://provider/out');

    expect(
      calls.map((MethodCall c) => c.method),
      <String>['beginWrite', 'writeChunk', 'endWrite'],
      reason:
          'the order is the contract: a chunk written outside a write has nowhere to land, and '
          'an end that precedes the last chunk claims a document that is not complete',
    );
  });

  test('a missing permission surfaces as a failure, not as success', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          throw PlatformException(
            code: 'NS-SAF',
            message: 'FileNotFoundException: no access',
          );
        });

    await expectLater(
      gateway.readChunk(uri: 'content://gone/1', offset: 0, length: 4),
      throwsA(isA<PlatformException>()),
      reason:
          'a URI permission that did not survive must fail loudly: AGENTS.md 搂9 wants BLOCKED '
          'rather than a silent second copy of the file',
    );
  });

  group('the in-memory double obeys the same rules', () {
    test('reads are bounded by the file and the request', () async {
      final InMemoryFileGateway memory = InMemoryFileGateway(
        documents: <String, Uint8List>{
          'mem://a': Uint8List.fromList(List<int>.generate(10, (int i) => i)),
        },
      );

      expect(
        await memory.readChunk(uri: 'mem://a', offset: 0, length: 4),
        <int>[0, 1, 2, 3],
      );
      expect(
        await memory.readChunk(uri: 'mem://a', offset: 8, length: 4),
        <int>[8, 9],
        reason: 'a read past the end returns what exists rather than padding',
      );
      expect(
        await memory.readChunk(uri: 'mem://a', offset: 10, length: 4),
        isEmpty,
      );
    });

    test('a written document is byte-identical to what went in', () async {
      final InMemoryFileGateway memory = InMemoryFileGateway();
      final Uint8List body = Uint8List.fromList(
        List<int>.generate(9, (int i) => i * 3),
      );

      await memory.beginWrite(uri: 'mem://out');
      await memory.writeChunk(
        uri: 'mem://out',
        offset: 0,
        bytes: Uint8List.sublistView(body, 0, 4),
      );
      await memory.writeChunk(
        uri: 'mem://out',
        offset: 4,
        bytes: Uint8List.sublistView(body, 4),
      );
      await memory.endWrite(uri: 'mem://out');

      expect(memory.written['mem://out'], body);
    });

    test('aborting a write discards it', () async {
      final InMemoryFileGateway memory = InMemoryFileGateway();
      await memory.beginWrite(uri: 'mem://out');
      await memory.writeChunk(
        uri: 'mem://out',
        offset: 0,
        bytes: Uint8List.fromList(<int>[1]),
      );
      await memory.abortWrite(uri: 'mem://out');
      expect(memory.written, isEmpty);
    });
  });
}
