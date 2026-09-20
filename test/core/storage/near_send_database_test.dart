import 'package:flutter_test/flutter_test.dart';

import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/storage/near_send_database.dart';
import 'package:nearsend/core/storage/storage_failure.dart';

/// Nested transactions.
///
/// `transaction` used to be flat: a second call ran `BEGIN IMMEDIATE` inside the first, which
/// SQLite refuses, so the failure surfaced as an opaque "transaction rolled back". That is not
/// an exotic shape - it is what an idempotent endpoint looks like, because §9 requires the
/// request-id record and the effect to share one transaction while the effect naturally calls
/// ordinary repository methods, each of which opens its own.
///
/// So these tests are about the two halves that matter: work inside a level **can** be undone
/// on its own without discarding the level outside it, and an outer failure **still** discards
/// everything. A savepoint implementation that got the second half wrong would be worse than no
/// nesting at all, because a partially applied transaction is the thing transactions exist to
/// prevent.
void main() {
  late NearSendDatabase database;

  setUp(() {
    database = NearSendDatabase.open(path: NearSendDatabase.inMemoryPath);
    database.db.execute(
      'CREATE TABLE scratch (id INTEGER PRIMARY KEY, note TEXT);',
    );
  });

  tearDown(() => database.close());

  int rowCount() =>
      database.db.select('SELECT COUNT(*) AS c FROM scratch;').first['c']
          as int;

  void insert(int id, String note) => database.db.execute(
    'INSERT INTO scratch (id, note) VALUES (?, ?);',
    <Object?>[id, note],
  );

  group('a single transaction', () {
    test('commits its work', () {
      final int result = database.transaction(() {
        insert(1, 'outer');
        return 7;
      });

      expect(result, 7, reason: 'the body value passes through');
      expect(rowCount(), 1);
    });

    test('rolls back its work', () {
      expect(
        () => database.transaction<void>(() {
          insert(1, 'outer');
          throw StateError('boom');
        }),
        throwsA(isA<StorageException>()),
      );
      expect(rowCount(), 0);
    });

    test('reports whether it is open', () {
      expect(database.inTransaction, isFalse);
      database.transaction<void>(() {
        expect(database.inTransaction, isTrue);
      });
      expect(database.inTransaction, isFalse);
    });
  });

  group('a nested transaction', () {
    test('commits with the outer one', () {
      database.transaction<void>(() {
        insert(1, 'outer');
        database.transaction<void>(() => insert(2, 'inner'));
      });
      expect(rowCount(), 2);
    });

    test('is undone when the outer one fails', () {
      // The half that must not be got wrong: an inner level succeeding must not survive an
      // outer failure.
      expect(
        () => database.transaction<void>(() {
          insert(1, 'outer');
          database.transaction<void>(() => insert(2, 'inner'));
          throw StateError('the outer level failed');
        }),
        throwsA(isA<StorageException>()),
      );
      expect(
        rowCount(),
        0,
        reason:
            'a savepoint that leaked a commit would leave half the work behind',
      );
    });

    test('can be undone on its own, leaving the outer work intact', () {
      database.transaction<void>(() {
        insert(1, 'outer');
        expect(
          () => database.transaction<void>(() {
            insert(2, 'inner');
            throw StateError('only the inner level fails');
          }),
          throwsA(isA<StorageException>()),
        );
        // The outer level is still usable and its own work is still there.
        insert(3, 'after');
      });

      expect(rowCount(), 2);
      final List<String> notes = <String>[
        for (final dynamic row in database.db.select(
          'SELECT note FROM scratch ORDER BY id;',
        ))
          row['note'] as String,
      ];
      expect(notes, <String>['outer', 'after']);
    });

    test('leaves no savepoint behind, so the level can be reused', () {
      // `ROLLBACK TO` keeps the savepoint on the stack; without the matching `RELEASE` a
      // second attempt at the same depth would fail on a duplicate name.
      database.transaction<void>(() {
        for (int attempt = 0; attempt < 3; attempt++) {
          expect(
            () => database.transaction<void>(() {
              insert(attempt, 'attempt $attempt');
              throw StateError('attempt $attempt fails');
            }),
            throwsA(isA<StorageException>()),
          );
        }
        insert(99, 'survivor');
      });

      expect(rowCount(), 1);
      expect(
        database.db.select('SELECT note FROM scratch;').first['note'],
        'survivor',
      );
    });

    test('three levels deep are all undone by the outer failure', () {
      expect(
        () => database.transaction<void>(() {
          insert(1, 'one');
          database.transaction<void>(() {
            insert(2, 'two');
            database.transaction<void>(() => insert(3, 'three'));
          });
          throw StateError('the outermost level failed');
        }),
        throwsA(isA<StorageException>()),
      );
      expect(rowCount(), 0);
    });

    test('propagates a protocol violation unchanged', () {
      // Relabelling it as a storage failure would tell the caller the disk failed when the
      // protocol did.
      expect(
        () => database.transaction<void>(() {
          insert(1, 'outer');
          database.transaction<void>(
            () => throw const ProtocolViolation(
              ProtocolErrorCode.invalidState,
              'not a state this operation applies to',
            ),
          );
        }),
        throwsA(
          isA<ProtocolViolation>().having(
            (ProtocolViolation e) => e.code,
            'code',
            ProtocolErrorCode.invalidState,
          ),
        ),
      );
      expect(rowCount(), 0);
    });
  });

  group('a read transaction', () {
    test('runs directly inside an open transaction', () {
      // A second `BEGIN` would be refused; a read inside a transaction is already inside one.
      database.transaction<void>(() {
        insert(1, 'outer');
        final int seen = database.readTransaction(
          () =>
              database.db
                      .select('SELECT COUNT(*) AS c FROM scratch;')
                      .first['c']
                  as int,
        );
        expect(
          seen,
          1,
          reason: 'the read sees the work the open transaction has not yet committed',
        );
      });
      expect(rowCount(), 1);
    });

    test('still works on its own', () {
      insert(1, 'outer');
      expect(database.readTransaction(rowCount), 1);
      expect(database.inTransaction, isFalse);
    });
  });
}
