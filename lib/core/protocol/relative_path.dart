/// Lexical validation of `relativePath`, per `docs/protocol/v1.0-draft1.md` §5.1.
///
/// The manifest's `relativePath` is metadata. §5.1 is explicit that it must not be
/// concatenated into a writable path, and that the storage adapter owns handle-level
/// escape protection. What this file does is the lexical half: reject anything the
/// protocol does not allow, so that a hostile or careless peer cannot place a value
/// in the frozen manifest that later layers would have to defend against.
///
/// Paths are normalised to NFC by the sender. Detecting a non-NFC path at the
/// receiver needs a Unicode normalisation implementation, which the Dart SDK does
/// not provide; see [RelativePathRules.enforcesNfcNormalisation].
library;

import 'dart:convert';

import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';

/// Rules and validation for the protocol's relative path field.
abstract final class RelativePathRules {
  /// Whether this validator rejects a path that is not NFC-normalised.
  ///
  /// `docs/protocol/v1.0-draft1.md` §5.1 requires the receiver to reject non-NFC
  /// input. Detecting that requires Unicode canonical decomposition and combining
  /// class data, which the Dart SDK does not ship. Selecting an implementation is a
  /// dependency decision: `AGENTS.md` §3 forbids settling such a choice by
  /// preference, and `docs/architecture/APP_AND_SERVICE_DESIGN.md` §12 requires the
  /// purpose, licence, maintenance status and security impact of a new package to
  /// be recorded first.
  ///
  /// Until that decision is made this validator does **not** enforce NFC, and the
  /// gap is tracked in `docs/PROJECT_LEDGER.md` §5. The flag exists so the gap is
  /// discoverable in code and greppable, rather than silently absent.
  static const bool enforcesNfcNormalisation = false;

  /// Characters that Windows forbids in a file name.
  ///
  /// `/` is deliberately absent: §5.1 makes it the one permitted separator, so it
  /// is handled by the segment split rather than rejected as a character. `\` and
  /// `:` are called out by §5.1 itself.
  static const Set<int> _windowsIllegal = <int>{
    0x3C, // <
    0x3E, // >
    0x3A, // :
    0x22, // "
    0x5C, // \
    0x7C, // |
    0x3F, // ?
    0x2A, // *
  };

  /// Reserved device names, matched case-insensitively and with or without an
  /// extension, as Windows resolves them.
  static const Set<String> _reservedNames = <String>{
    'CON', 'PRN', 'AUX', 'NUL', //
    'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9', //
    'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
  };

  /// Validates [path] and returns it unchanged.
  ///
  /// The returned value is the exact string that participates in the manifest
  /// digest: §5.1 forbids silently rewriting a name, because that would change the
  /// bytes the sender signed.
  static String validate(String path) {
    if (path.isEmpty) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidPath,
        'relative path must not be empty',
      );
    }

    final int byteLength = utf8.encode(path).length;
    if (byteLength < ProtocolLimits.minPathBytes ||
        byteLength > ProtocolLimits.maxPathBytes) {
      throw ProtocolViolation(
        ProtocolErrorCode.invalidPath,
        'relative path must be ${ProtocolLimits.minPathBytes}..'
        '${ProtocolLimits.maxPathBytes} UTF-8 bytes, got $byteLength',
      );
    }

    _rejectUnpairedSurrogates(path);

    if (path.startsWith('/')) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidPath,
        'relative path must not be absolute',
      );
    }
    if (path.endsWith('/')) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidPath,
        'relative path must not end with a separator',
      );
    }

    for (final int unit in path.codeUnits) {
      if (unit < 0x20 || unit == 0x7F) {
        throw const ProtocolViolation(
          ProtocolErrorCode.invalidPath,
          'relative path must not contain control characters',
        );
      }
      if (_windowsIllegal.contains(unit)) {
        throw const ProtocolViolation(
          ProtocolErrorCode.invalidPath,
          'relative path contains a character that is not allowed',
        );
      }
    }

    final List<String> segments = path.split('/');
    for (final String segment in segments) {
      if (segment.isEmpty) {
        throw const ProtocolViolation(
          ProtocolErrorCode.invalidPath,
          'relative path must not contain an empty segment',
        );
      }
      if (segment == '.' || segment == '..') {
        throw const ProtocolViolation(
          ProtocolErrorCode.invalidPath,
          'relative path must not contain a dot segment',
        );
      }
      if (segment.endsWith(' ') || segment.endsWith('.')) {
        throw const ProtocolViolation(
          ProtocolErrorCode.invalidPath,
          'a path segment must not end with a space or a dot',
        );
      }
      if (_isReservedName(segment)) {
        throw const ProtocolViolation(
          ProtocolErrorCode.invalidPath,
          'a path segment uses a reserved device name',
        );
      }
    }

    return path;
  }

  static bool _isReservedName(String segment) {
    final int dot = segment.indexOf('.');
    final String stem = (dot == -1 ? segment : segment.substring(0, dot))
        .toUpperCase();
    return _reservedNames.contains(stem);
  }

  /// Rejects lone surrogates, which are not valid UTF-8 and would otherwise be
  /// replaced by U+FFFD during encoding, changing the bytes that are digested.
  static void _rejectUnpairedSurrogates(String value) {
    for (int i = 0; i < value.length; i++) {
      final int unit = value.codeUnitAt(i);
      final bool isHigh = unit >= 0xD800 && unit <= 0xDBFF;
      final bool isLow = unit >= 0xDC00 && unit <= 0xDFFF;
      if (isHigh) {
        if (i + 1 >= value.length) {
          throw const ProtocolViolation(
            ProtocolErrorCode.invalidPath,
            'relative path ends with an unpaired high surrogate',
          );
        }
        final int next = value.codeUnitAt(i + 1);
        if (next < 0xDC00 || next > 0xDFFF) {
          throw const ProtocolViolation(
            ProtocolErrorCode.invalidPath,
            'relative path contains an unpaired high surrogate',
          );
        }
        i++;
      } else if (isLow) {
        throw ProtocolViolation(
          ProtocolErrorCode.invalidPath,
          'relative path contains an unpaired low surrogate at $i',
        );
      }
    }
  }
}
