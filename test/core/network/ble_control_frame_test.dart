import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/network/ble_control_frame.dart';

void main() {
  group('BLE control framing', () {
    test('round trips a message at the minimum practical frame size', () {
      final BleControlMessage message = BleControlMessage(
        type: BleControlMessageType.bootstrap,
        sessionTag: 0x12345678,
        sequence: 7,
        payload: Uint8List.fromList(List<int>.generate(257, (int i) => i)),
      );
      final List<Uint8List> frames = fragmentBleControlMessage(
        message,
        maximumFrameBytes: 20,
      );
      final BleControlReassembler reassembler = BleControlReassembler();
      BleControlMessage? decoded;

      for (final Uint8List frame in frames) {
        expect(frame.length, lessThanOrEqualTo(20));
        decoded = reassembler.add('peer-a', frame) ?? decoded;
      }

      expect(frames, hasLength(65));
      expect(decoded, isNotNull);
      expect(decoded!.type, message.type);
      expect(decoded.sessionTag, message.sessionTag);
      expect(decoded.sequence, message.sequence);
      expect(decoded.payload, message.payload);
      expect(reassembler.bufferedBytes, 0);
    });

    test('supports the bounded maximum logical message', () {
      final BleControlMessage message = BleControlMessage(
        type: BleControlMessageType.control,
        sessionTag: 1,
        sequence: 0,
        payload: Uint8List(bleControlMaxMessageBytes),
      );
      final List<Uint8List> frames = fragmentBleControlMessage(
        message,
        maximumFrameBytes: bleControlMaxFrameBytes,
      );
      final BleControlReassembler reassembler = BleControlReassembler();
      BleControlMessage? decoded;
      for (final Uint8List frame in frames) {
        decoded = reassembler.add('peer-a', frame) ?? decoded;
      }

      expect(decoded!.payload, hasLength(bleControlMaxMessageBytes));
      expect(frames, hasLength(34));
    });

    test('rejects malformed versions, types, lengths and fragments', () {
      final Uint8List valid = fragmentBleControlMessage(
        BleControlMessage(
          type: BleControlMessageType.control,
          sessionTag: 1,
          sequence: 0,
          payload: Uint8List.fromList(<int>[1, 2, 3]),
        ),
        maximumFrameBytes: 20,
      ).single;

      Uint8List changed(int index, int value) {
        final Uint8List copy = Uint8List.fromList(valid);
        copy[index] = value;
        return copy;
      }

      expect(
        () => BleControlFrame.decode(changed(0, 0)),
        throwsA(_error(BleControlProtocolError.malformedFrame)),
      );
      expect(
        () => BleControlFrame.decode(changed(1, 0x23)),
        throwsA(_error(BleControlProtocolError.unsupportedVersion)),
      );
      expect(
        () => BleControlFrame.decode(changed(1, 0x1f)),
        throwsA(_error(BleControlProtocolError.unsupportedType)),
      );
      expect(
        () => BleControlFrame.decode(changed(15, 4)),
        throwsA(_error(BleControlProtocolError.invalidLength)),
      );
      expect(
        () => BleControlFrame.decode(Uint8List(bleControlMaxFrameBytes + 1)),
        throwsA(_error(BleControlProtocolError.malformedFrame)),
      );
    });

    test('rejects duplicate, out-of-order and replayed fragments', () {
      final List<Uint8List> frames = fragmentBleControlMessage(
        BleControlMessage(
          type: BleControlMessageType.bootstrapResponse,
          sessionTag: 2,
          sequence: 8,
          payload: Uint8List.fromList(List<int>.generate(30, (int i) => i)),
        ),
        maximumFrameBytes: 20,
      );
      final BleControlReassembler reassembler = BleControlReassembler();

      expect(
        () => reassembler.add('peer-a', frames[1]),
        throwsA(_error(BleControlProtocolError.unexpectedFragment)),
      );
      expect(reassembler.add('peer-a', frames[0]), isNull);
      expect(
        () => reassembler.add('peer-a', frames[0]),
        throwsA(_error(BleControlProtocolError.unexpectedFragment)),
      );

      BleControlMessage? decoded;
      for (final Uint8List frame in frames) {
        decoded = reassembler.add('peer-a', frame) ?? decoded;
      }
      expect(decoded, isNotNull);
      expect(
        () => reassembler.add('peer-a', frames.first),
        throwsA(_error(BleControlProtocolError.replayedSequence)),
      );
    });

    test('drops a partial message after the assembly deadline', () {
      DateTime now = DateTime.utc(2026, 9, 24);
      final BleControlReassembler reassembler = BleControlReassembler(
        timeout: const Duration(seconds: 2),
        clock: () => now,
      );
      final List<Uint8List> frames = fragmentBleControlMessage(
        BleControlMessage(
          type: BleControlMessageType.control,
          sessionTag: 3,
          sequence: 1,
          payload: Uint8List(30),
        ),
        maximumFrameBytes: 20,
      );

      expect(reassembler.add('peer-a', frames.first), isNull);
      expect(reassembler.bufferedBytes, 4);
      now = now.add(const Duration(seconds: 3));
      expect(
        () => reassembler.add('peer-b', frames.first),
        throwsA(_error(BleControlProtocolError.assemblyExpired)),
      );
      expect(reassembler.bufferedBytes, 0);
    });

    test('a newer sequence replaces an interrupted partial message', () {
      final BleControlReassembler reassembler = BleControlReassembler();
      final List<Uint8List> interrupted = fragmentBleControlMessage(
        BleControlMessage(
          type: BleControlMessageType.control,
          sessionTag: 4,
          sequence: 10,
          payload: Uint8List(12),
        ),
        maximumFrameBytes: 20,
      );
      final Uint8List replacement = fragmentBleControlMessage(
        BleControlMessage(
          type: BleControlMessageType.abort,
          sessionTag: 4,
          sequence: 11,
          payload: Uint8List.fromList(<int>[9]),
        ),
        maximumFrameBytes: 20,
      ).single;

      expect(reassembler.add('peer-a', interrupted.first), isNull);
      final BleControlMessage? decoded = reassembler.add('peer-a', replacement);
      expect(decoded!.sequence, 11);
      expect(decoded.type, BleControlMessageType.abort);
      expect(
        () => reassembler.add('peer-a', interrupted.first),
        throwsA(_error(BleControlProtocolError.replayedSequence)),
      );
    });

    test('validates sender limits before allocating fragments', () {
      expect(
        () => BleControlMessage(
          type: BleControlMessageType.control,
          sessionTag: 0,
          sequence: 0,
          payload: Uint8List(0),
        ),
        throwsArgumentError,
      );
      expect(
        () => BleControlMessage(
          type: BleControlMessageType.control,
          sessionTag: 0,
          sequence: 0,
          payload: Uint8List(bleControlMaxMessageBytes + 1),
        ),
        throwsArgumentError,
      );
      final BleControlMessage valid = BleControlMessage(
        type: BleControlMessageType.control,
        sessionTag: 0,
        sequence: 0,
        payload: Uint8List(1),
      );
      expect(
        () => fragmentBleControlMessage(
          valid,
          maximumFrameBytes: bleControlFrameHeaderBytes,
        ),
        throwsArgumentError,
      );
    });

    test('bounds peer state retained by the reassembler', () {
      final BleControlReassembler reassembler = BleControlReassembler();
      Uint8List firstFrame(int sessionTag) => fragmentBleControlMessage(
        BleControlMessage(
          type: BleControlMessageType.control,
          sessionTag: sessionTag,
          sequence: 0,
          payload: Uint8List(8),
        ),
        maximumFrameBytes: 20,
      ).first;

      for (int index = 0; index < bleControlMaxActivePeers; index++) {
        expect(reassembler.add('peer-$index', firstFrame(index)), isNull);
      }
      expect(
        () => reassembler.add('peer-overflow', firstFrame(99)),
        throwsA(_error(BleControlProtocolError.invalidFragment)),
      );
    });
  });
}

Matcher _error(BleControlProtocolError code) =>
    isA<BleControlProtocolException>().having(
      (BleControlProtocolException value) => value.code,
      'code',
      code,
    );
