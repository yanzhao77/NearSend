import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/transfer_direction.dart';

/// §7's direction vocabulary.
///
/// The values are protocol detail, so what matters is that exactly the two §7 spells are
/// accepted, that nothing else is guessed at, and that the two chunk endpoints' rules are
/// derived from the direction rather than restated in a comparison somewhere.
void main() {
  group('the wire vocabulary', () {
    test('exactly the two values §7 uses', () {
      expect(
        TransferDirection.values
            .map((TransferDirection d) => d.wireValue)
            .toSet(),
        <String>{'client_to_server', 'server_to_client'},
      );
    });

    test('parses both directions', () {
      expect(
        TransferDirection.parse('client_to_server'),
        TransferDirection.clientToServer,
      );
      expect(
        TransferDirection.parse('server_to_client'),
        TransferDirection.serverToClient,
      );
    });

    test('refuses anything else rather than picking one', () {
      for (final String value in <String>[
        '',
        'client-to-server',
        'CLIENT_TO_SERVER',
        'client_to_server ',
        'bidirectional',
      ]) {
        expect(
          () => TransferDirection.parse(value),
          throwsA(
            isA<ProtocolViolation>().having(
              (ProtocolViolation e) => e.code,
              'code',
              ProtocolErrorCode.invalidField,
            ),
          ),
          reason: '"$value" is not one of §7s two values',
        );
        expect(TransferDirection.fromWireValue(value), isNull);
      }
    });

    test('the parse failure names the value it was checking', () {
      expect(
        () => TransferDirection.parse('sideways', 'the transfer direction'),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.detail,
            'detail',
            contains('the transfer direction'),
          ),
        ),
      );
    });
  });

  group('the derived endpoint rules', () {
    test('the chunk upload belongs to client_to_server only', () {
      expect(TransferDirection.clientToServer.permitsChunkUpload, isTrue);
      expect(
        TransferDirection.serverToClient.permitsChunkUpload,
        isFalse,
        reason: '§7 marks PUT .../chunks/{index} as 仅 client_to_server',
      );
    });

    test('the chunk download belongs to server_to_client only', () {
      expect(TransferDirection.serverToClient.permitsChunkDownload, isTrue);
      expect(
        TransferDirection.clientToServer.permitsChunkDownload,
        isFalse,
        reason: '§7 marks GET .../chunks/{index} as 仅 server_to_client',
      );
    });

    test('the two permissions are exact opposites', () {
      for (final TransferDirection direction in TransferDirection.values) {
        expect(
          direction.permitsChunkUpload,
          isNot(direction.permitsChunkDownload),
          reason:
              'the same direction cannot both accept a chunk and offer one; the names '
              'describe the data, so the two endpoints are opposite halves',
        );
      }
    });

    test('opposite returns the other one', () {
      expect(
        TransferDirection.clientToServer.opposite,
        TransferDirection.serverToClient,
      );
      expect(
        TransferDirection.serverToClient.opposite,
        TransferDirection.clientToServer,
      );
    });

    test('only client_to_server may be proposed by a client', () {
      expect(
        TransferDirection.clientProposable,
        TransferDirection.clientToServer,
        reason: '§7: 客户端仅可提议 client_to_server',
      );
    });

    test('renders as the wire value, not the Dart name', () {
      expect('${TransferDirection.clientToServer}', 'client_to_server');
    });
  });
}
