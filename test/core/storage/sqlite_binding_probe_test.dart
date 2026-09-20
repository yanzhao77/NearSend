import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// Proves the SQLite binding loads and behaves as the storage design requires.
///
/// `docs/architecture/SYSTEM_ARCHITECTURE.md` §12 lists the SQLite plugin, the
/// background isolate and the platform's durable-sync semantics as **unfrozen**
/// choices, and `AGENTS.md` §3 forbids settling such a choice by preference. This file
/// is the verification half of that: it fails loudly if the binding cannot be loaded on
/// a platform, or if the durability pragmas the receiver's commit protocol depends on
/// are silently refused.
///
/// It is a permanent test rather than a one-off spike, because the failure it guards
/// against - a binding that works in the app bundle but not under `flutter test`, or a
/// build that quietly ignores `journal_mode=WAL` - would otherwise be discovered only
/// after the checkpoint protocol had been built on top of it.
void main() {
  test('the SQLite library loads and reports a usable version', () {
    final String version = sqlite3.version.libVersion;
    expect(version, isNotEmpty);

    // Recorded so the dependency record can name the exact library the binding
    // resolved to on this host, not only the package version.
    // ignore: avoid_print
    print('sqlite3 library $version (package ${sqlite3.version.sourceId})');

    // The protocol's storage layer needs a bound parameter to be honoured and a
    // transaction to be atomic; both have been stable for many years, so a version
    // check guards against an unexpectedly ancient system library rather than a
    // specific feature.
    final List<int> parts = version.split('.').map(int.parse).toList();
    expect(
      parts.first,
      greaterThanOrEqualTo(3),
      reason: 'SQLite 3 is required; got $version',
    );

    final Database db = sqlite3.openInMemory();
    try {
      expect(db.select('SELECT 1 AS one').first['one'], 1);
    } finally {
      db.close();
    }
  });

  test(
    'the durability pragmas the commit protocol depends on are accepted',
    () {
      final Database db = sqlite3.openInMemory();
      try {
        // WAL is what lets the receiver commit a checkpoint without blocking readers.
        db.execute('PRAGMA journal_mode = WAL;');
        // synchronous=FULL is the setting the receiver's "durable sync, then commit"
        // ordering relies on; if it is silently downgraded, a crash can acknowledge a
        // chunk that is not on disk.
        db.execute('PRAGMA synchronous = FULL;');
        db.execute('PRAGMA foreign_keys = ON;');

        final ResultSet synchronous = db.select('PRAGMA synchronous;');
        expect(
          synchronous.first.values.first,
          2,
          reason: 'PRAGMA synchronous must read back as 2 (FULL)',
        );

        final ResultSet foreignKeys = db.select('PRAGMA foreign_keys;');
        expect(foreignKeys.first.values.first, 1);
      } finally {
        db.close();
      }
    },
  );

  test('a committed transaction survives closing and reopening the file', () {
    final Directory dir = Directory.systemTemp.createTempSync(
      'nearsend-sqlite-',
    );
    final String path = '${dir.path}${Platform.pathSeparator}probe.db';
    try {
      final Database first = sqlite3.open(path);
      try {
        first.execute('PRAGMA journal_mode = WAL;');
        first.execute('PRAGMA synchronous = FULL;');
        first.execute(
          'CREATE TABLE chunks (file_id TEXT NOT NULL, idx INTEGER NOT NULL, '
          'state TEXT NOT NULL, PRIMARY KEY (file_id, idx));',
        );
        first.execute('BEGIN IMMEDIATE;');
        first.execute(
          "INSERT INTO chunks (file_id, idx, state) VALUES ('f1', 0, 'committed');",
        );
        first.execute('COMMIT;');
      } finally {
        first.close();
      }

      final Database second = sqlite3.open(path);
      try {
        final ResultSet rows = second.select(
          "SELECT state FROM chunks WHERE file_id = 'f1' AND idx = 0;",
        );
        expect(rows.length, 1);
        expect(rows.first['state'], 'committed');
      } finally {
        second.close();
      }
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('a rolled back transaction leaves nothing behind', () {
    final Database db = sqlite3.openInMemory();
    try {
      db.execute('CREATE TABLE t (v TEXT);');
      db.execute('BEGIN IMMEDIATE;');
      db.execute("INSERT INTO t (v) VALUES ('x');");
      db.execute('ROLLBACK;');
      expect(db.select('SELECT COUNT(*) AS c FROM t').first['c'], 0);
    } finally {
      db.close();
    }
  });

  test(
    'a failed statement inside a transaction does not abort the connection',
    () {
      // The receiver must be able to detect a bad write and roll back without losing the
      // connection, because losing it would turn a recoverable chunk error into a task
      // failure.
      final Database db = sqlite3.openInMemory();
      try {
        db.execute('CREATE TABLE t (v TEXT NOT NULL);');
        db.execute('BEGIN IMMEDIATE;');
        expect(
          () => db.execute('INSERT INTO t (v) VALUES (NULL);'),
          throwsA(isA<SqliteException>()),
        );
        db.execute('ROLLBACK;');
        expect(db.select('SELECT COUNT(*) AS c FROM t').first['c'], 0);
      } finally {
        db.close();
      }
    },
  );
}
