/// Strict decoding of a control body, `docs/protocol/v1.0-draft1.md` §4 and §7.
///
/// §4 fixes the rules:
///
/// > 控制体 application/json; charset=utf-8，单请求/响应最大 1 MiB；JSON 深度最多 16，
/// > 重复对象键、NaN/Infinity、非法 Unicode 拒绝。内容按 UTF-8 解释，不接受 BOM。
///
/// ## Why this is not just `jsonDecode`
///
/// Dart's decoder is a fine JSON parser and rejects malformed syntax, but it does **not**
/// reject a duplicate object key: it keeps the last one and says nothing. That is exactly
/// the shape of a parser-differential attack - two implementations read the same bytes and
/// disagree about the value, so a receiver that authorises on one reading and acts on
/// another can be steered. §4 closes it by rejecting the body.
///
/// The same reasoning applies to depth: `jsonDecode` will recurse as far as the input
/// takes it, so the 16 level limit has to be enforced *while* scanning.
///
/// So the body is scanned once for structure - depth, duplicate keys, escape handling -
/// and then handed to `jsonDecode` for the values. The scanner deliberately does not build
/// values: two parsers that both build would be two chances to disagree, and this one only
/// has to agree with itself about where the structure ends.
///
/// ## Where a duplicate key can hide
///
/// `{"a":1,"\u0061":2}` has two *different* source spellings of the same key. A scanner
/// that compared raw source text would call that body valid and let `jsonDecode` silently
/// pick one. The scanner therefore decodes string escapes - including surrogate pairs -
/// before comparing, which is the only way the check means what §4 says it means.
library;

import 'dart:convert';

import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';

/// The UTF-8 BOM, which §4 says a control body must not start with.
const List<int> _utf8Bom = <int>[0xEF, 0xBB, 0xBF];

/// Decodes a control body into a JSON object.
///
/// Throws [ProtocolViolation] for anything §4 does not allow. The body is never partially
/// accepted: a half-understood control message is worse than a rejected one, because the
/// caller cannot tell which half it understood.
Map<String, Object?> decodeControlBody(
  List<int> bytes, {
  String scope = 'the control body',
}) {
  if (bytes.length > ProtocolLimits.controlBodyMaxBytes) {
    throw ProtocolViolation(
      ProtocolErrorCode.bodyTooLarge,
      '$scope is ${bytes.length} bytes, over the '
      '${ProtocolLimits.controlBodyMaxBytes} byte limit',
    );
  }

  if (bytes.length >= 3 &&
      bytes[0] == _utf8Bom[0] &&
      bytes[1] == _utf8Bom[1] &&
      bytes[2] == _utf8Bom[2]) {
    throw ProtocolViolation(
      ProtocolErrorCode.invalidField,
      '$scope must not start with a byte order mark',
    );
  }

  final String source;
  try {
    // allowMalformed defaults to false, so an invalid sequence throws rather than being
    // replaced by U+FFFD - which would change the bytes a digest or a key comparison sees.
    source = utf8.decode(bytes);
  } on FormatException {
    throw ProtocolViolation(
      ProtocolErrorCode.invalidField,
      '$scope is not valid UTF-8',
    );
  }

  _JsonScanner(source, scope).validateDocument();

  final Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on FormatException {
    throw ProtocolViolation(
      ProtocolErrorCode.invalidField,
      '$scope is not valid JSON',
    );
  }

  if (decoded is! Map<String, Object?>) {
    throw ProtocolViolation(
      ProtocolErrorCode.invalidField,
      '$scope must be a JSON object',
    );
  }
  return decoded;
}

/// Validates JSON structure under §4's rules without building values.
class _JsonScanner {
  _JsonScanner(this._source, this._scope);

  final String _source;
  final String _scope;
  int _index = 0;

  void validateDocument() {
    _skipWhitespace();
    _scanValue(0);
    _skipWhitespace();
    if (_index != _source.length) {
      _fail('has trailing content after the top level value');
    }
  }

  void _scanValue(int depth) {
    if (depth > ProtocolLimits.maxJsonDepth) {
      _fail('nests deeper than ${ProtocolLimits.maxJsonDepth} levels');
    }
    if (_index >= _source.length) {
      _fail('ends in the middle of a value');
    }
    switch (_source.codeUnitAt(_index)) {
      case 0x7B: // {
        _scanObject(depth);
      case 0x5B: // [
        _scanArray(depth);
      case 0x22: // "
        _readString();
      case 0x74: // t
        _expectLiteral('true');
      case 0x66: // f
        _expectLiteral('false');
      case 0x6E: // n
        _expectLiteral('null');
      default:
        _scanNumber();
    }
  }

  void _scanObject(int depth) {
    _index++; // consume {
    _skipWhitespace();
    final Set<String> keys = <String>{};
    if (_peekIs(0x7D)) {
      _index++;
      return;
    }
    while (true) {
      _skipWhitespace();
      if (!_peekIs(0x22)) {
        _fail('has an object key that is not a string');
      }
      final String key = _readString();
      if (!keys.add(key)) {
        // The point of the whole scanner: §4 rejects a repeated key rather than letting
        // the decoder silently choose one of the values. The key is not echoed back - it
        // came from the body, and a control body can carry a token.
        _fail('repeats an object key');
      }
      _skipWhitespace();
      if (!_peekIs(0x3A)) {
        _fail('has an object key without a value');
      }
      _index++; // consume :
      _skipWhitespace();
      _scanValue(depth + 1);
      _skipWhitespace();
      if (_peekIs(0x2C)) {
        _index++; // consume ,
        continue;
      }
      if (_peekIs(0x7D)) {
        _index++; // consume }
        return;
      }
      _fail('has an object that is neither continued nor closed');
    }
  }

  void _scanArray(int depth) {
    _index++; // consume [
    _skipWhitespace();
    if (_peekIs(0x5D)) {
      _index++;
      return;
    }
    while (true) {
      _skipWhitespace();
      _scanValue(depth + 1);
      _skipWhitespace();
      if (_peekIs(0x2C)) {
        _index++;
        continue;
      }
      if (_peekIs(0x5D)) {
        _index++;
        return;
      }
      _fail('has an array that is neither continued nor closed');
    }
  }

  /// Reads a string and returns its decoded value, so escape spellings compare equal.
  String _readString() {
    _index++; // consume the opening quote
    final StringBuffer out = StringBuffer();
    while (true) {
      if (_index >= _source.length) {
        _fail('has an unterminated string');
      }
      final int unit = _source.codeUnitAt(_index);
      if (unit == 0x22) {
        _index++;
        return out.toString();
      }
      if (unit == 0x5C) {
        _readEscape(out);
        continue;
      }
      if (unit < 0x20) {
        _fail('has an unescaped control character in a string');
      }
      out.writeCharCode(unit);
      _index++;
    }
  }

  void _readEscape(StringBuffer out) {
    _index++; // consume the backslash
    if (_index >= _source.length) {
      _fail('ends with an incomplete escape');
    }
    final int unit = _source.codeUnitAt(_index);
    _index++;
    switch (unit) {
      case 0x22:
        out.writeCharCode(0x22);
      case 0x5C:
        out.writeCharCode(0x5C);
      case 0x2F:
        out.writeCharCode(0x2F);
      case 0x62:
        out.writeCharCode(0x08);
      case 0x66:
        out.writeCharCode(0x0C);
      case 0x6E:
        out.writeCharCode(0x0A);
      case 0x72:
        out.writeCharCode(0x0D);
      case 0x74:
        out.writeCharCode(0x09);
      case 0x75:
        _readUnicodeEscape(out);
      default:
        _fail('has an invalid escape sequence');
    }
  }

  void _readUnicodeEscape(StringBuffer out) {
    final int first = _readHex4();
    // A surrogate pair spells one character as two escapes. Writing the high surrogate on
    // its own would leave a lone surrogate in the decoded string, which is a different key
    // from the same character spelled properly - so the pair is assembled here.
    if (first >= 0xD800 && first <= 0xDBFF) {
      if (_index + 1 < _source.length &&
          _source.codeUnitAt(_index) == 0x5C &&
          _source.codeUnitAt(_index + 1) == 0x75) {
        _index += 2;
        final int second = _readHex4();
        if (second >= 0xDC00 && second <= 0xDFFF) {
          out.writeCharCode(
            0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00),
          );
          return;
        }
        _fail('has an unpaired high surrogate in an escape');
      }
      _fail('has an unpaired high surrogate in an escape');
    }
    if (first >= 0xDC00 && first <= 0xDFFF) {
      _fail('has an unpaired low surrogate in an escape');
    }
    out.writeCharCode(first);
  }

  int _readHex4() {
    if (_index + 4 > _source.length) {
      _fail('ends with an incomplete unicode escape');
    }
    int value = 0;
    for (int i = 0; i < 4; i++) {
      final int digit = _hexValue(_source.codeUnitAt(_index + i));
      if (digit < 0) {
        _fail('has a non-hexadecimal digit in a unicode escape');
      }
      value = (value << 4) | digit;
    }
    _index += 4;
    return value;
  }

  static int _hexValue(int unit) {
    if (unit >= 0x30 && unit <= 0x39) {
      return unit - 0x30;
    }
    if (unit >= 0x61 && unit <= 0x66) {
      return unit - 0x61 + 10;
    }
    if (unit >= 0x41 && unit <= 0x46) {
      return unit - 0x41 + 10;
    }
    return -1;
  }

  void _expectLiteral(String literal) {
    if (!_source.startsWith(literal, _index)) {
      _fail('has a value that is not valid JSON');
    }
    _index += literal.length;
  }

  /// Scans a number with JSON's grammar, which is what excludes `NaN` and `Infinity`.
  void _scanNumber() {
    final int start = _index;
    if (_peekIs(0x2D)) {
      _index++;
    }
    if (_index >= _source.length) {
      _fail('ends in the middle of a number');
    }
    if (_peekIs(0x30)) {
      _index++;
    } else if (_isDigitOneToNine(_source.codeUnitAt(_index))) {
      while (_index < _source.length && _isDigit(_source.codeUnitAt(_index))) {
        _index++;
      }
    } else {
      _fail('has a number that does not start with a digit');
    }
    if (_peekIs(0x2E)) {
      _index++;
      if (_index >= _source.length || !_isDigit(_source.codeUnitAt(_index))) {
        _fail('has a fraction without digits');
      }
      while (_index < _source.length && _isDigit(_source.codeUnitAt(_index))) {
        _index++;
      }
    }
    if (_peekIs(0x65) || _peekIs(0x45)) {
      _index++;
      if (_peekIs(0x2B) || _peekIs(0x2D)) {
        _index++;
      }
      if (_index >= _source.length || !_isDigit(_source.codeUnitAt(_index))) {
        _fail('has an exponent without digits');
      }
      while (_index < _source.length && _isDigit(_source.codeUnitAt(_index))) {
        _index++;
      }
    }
    if (_index == start) {
      _fail('has a value that is not valid JSON');
    }
  }

  static bool _isDigit(int unit) => unit >= 0x30 && unit <= 0x39;

  static bool _isDigitOneToNine(int unit) => unit >= 0x31 && unit <= 0x39;

  bool _peekIs(int unit) =>
      _index < _source.length && _source.codeUnitAt(_index) == unit;

  void _skipWhitespace() {
    while (_index < _source.length) {
      final int unit = _source.codeUnitAt(_index);
      if (unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D) {
        _index++;
      } else {
        return;
      }
    }
  }

  Never _fail(String problem) {
    // The offset is included, and the offending text is not: a control body can carry a
    // token, and an error string reaches logs.
    throw ProtocolViolation(
      ProtocolErrorCode.invalidField,
      '$_scope $problem (at character $_index)',
    );
  }
}
