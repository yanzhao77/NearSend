// S0 probe: what does `dart:io`'s HttpServer hide from a handler?
//
// `docs/protocol/v1.0-draft1.md` §8 fixes framing rules with an unusually large blast
// radius - "一条两个跳数对『它在哪里结束』有分歧的消息，是一条可以被切成两条的消息" -
// and `chunk_headers.dart` implements them as pure functions over a header map. That only
// works if the header map a `dart:io` handler receives still contains what the peer sent.
//
// `dart:io` parses HTTP itself, so some hostile shapes may be normalized, merged, or acted
// on before any of our code runs. This probe sends them over a raw socket and prints what
// the handler actually sees, so the transport layer can state honestly which rules it
// enforces and which the engine enforces for it.
//
// Run:
//   dart run tooling/spikes/http_framing/main.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

Future<void> main() async {
  final HttpServer server = await HttpServer.bind(
    InternetAddress.loopbackIPv4,
    0,
  );
  final List<_Observed> observed = <_Observed>[];

  unawaited(
    server.listen((HttpRequest request) async {
      final List<String> rawContentLength =
          request.headers['content-length'] ?? const <String>[];
      final List<String> rawTransferEncoding =
          request.headers['transfer-encoding'] ?? const <String>[];
      final List<String> rawContentEncoding =
          request.headers['content-encoding'] ?? const <String>[];

      int bodyLength = 0;
      String note = 'handled';
      try {
        await for (final List<int> part in request) {
          bodyLength += part.length;
        }
      } on Object catch (error) {
        note = 'reading the body threw ${error.runtimeType}: $error';
        observed.add(
          _Observed(
            route: request.uri.path,
            reachedHandler: true,
            note: note,
            contentLengthValues: rawContentLength,
            transferEncodingValues: rawTransferEncoding,
            contentEncodingValues: rawContentEncoding,
            declaredContentLength: request.contentLength,
            bodyBytesRead: bodyLength,
          ),
        );
        return;
      }

      request.response.statusCode = 200;
      request.response.write('ok');
      await request.response.close();
      observed.add(
        _Observed(
          route: request.uri.path,
          reachedHandler: true,
          note: note,
          contentLengthValues: rawContentLength,
          transferEncodingValues: rawTransferEncoding,
          contentEncodingValues: rawContentEncoding,
          declaredContentLength: request.contentLength,
          bodyBytesRead: bodyLength,
        ),
      );
    }).asFuture<void>(),
  );

  final int port = server.port;
  stdout.writeln('probe server on 127.0.0.1:$port\n');

  final Map<String, String> cases = <String, String>{
    'A: well-formed, single Content-Length':
        'POST /a HTTP/1.1\r\nHost: probe\r\nContent-Length: 5\r\n\r\nhello',
    'B: two Content-Length headers': 'POST /b HTTP/1.1\r\nHost: probe\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\nhello',
    'C: Transfer-Encoding: chunked': 'POST /c HTTP/1.1\r\nHost: probe\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n',
    'D: Content-Length AND Transfer-Encoding': 'POST /d HTTP/1.1\r\nHost: probe\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n',
    'E: Content-Encoding: gzip': 'POST /e HTTP/1.1\r\nHost: probe\r\nContent-Encoding: gzip\r\nContent-Length: 5\r\n\r\nhello',
    'F: Content-Length with leading zeros':
        'POST /f HTTP/1.1\r\nHost: probe\r\nContent-Length: 005\r\n\r\nhello',
    'G: two spellings of the same header': 'POST /g HTTP/1.1\r\nHost: probe\r\nContent-Length: 5\r\ncontent-length: 6\r\n\r\nhello',
  };

  for (final MapEntry<String, String> entry in cases.entries) {
    stdout.writeln('=== $entry.key ===');
    final int before = observed.length;
    final String? reply = await _send(port, entry.value);
    stdout.writeln('client saw: ${reply ?? '<no reply / connection closed>'}');

    _Observed? seen;
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 3));
    while (DateTime.now().isBefore(deadline) && observed.length == before) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (observed.length > before) {
      seen = observed.last;
    }

    if (seen == null) {
      stdout.writeln('handler    : NEVER REACHED (the engine refused it)');
    } else {
      stdout.writeln(
        'handler    : reached=${seen.reachedHandler} ${seen.note}',
      );
      stdout.writeln(
        '  content-length values  : ${seen.contentLengthValues} '
        '(request.contentLength=${seen.declaredContentLength})',
      );
      stdout.writeln(
        '  transfer-encoding values: ${seen.transferEncodingValues}',
      );
      stdout.writeln(
        '  content-encoding values : ${seen.contentEncodingValues}',
      );
      stdout.writeln('  body bytes read         : ${seen.bodyBytesRead}');
    }
    stdout.writeln('');
  }

  await server.close(force: true);
}

/// Sends [request] over a raw socket and returns the raw reply, if any.
///
/// Completes on the **first** bytes received rather than on the connection closing: HTTP/1.1
/// keeps the connection alive, so waiting for `onDone` would report "no reply" for a request
/// the server answered correctly.
Future<String?> _send(int port, String request) async {
  final Socket socket = await Socket.connect(
    InternetAddress.loopbackIPv4,
    port,
  );
  socket.write(request);
  await socket.flush();

  final Completer<String?> done = Completer<String?>();
  final BytesBuilder response = BytesBuilder();
  socket.listen(
    (List<int> data) {
      response.add(data);
      if (!done.isCompleted) {
        done.complete(utf8.decode(response.takeBytes(), allowMalformed: true));
      }
    },
    onDone: () {
      if (!done.isCompleted) {
        done.complete(
          response.isEmpty
              ? null
              : utf8.decode(response.takeBytes(), allowMalformed: true),
        );
      }
    },
    onError: (Object _) {
      if (!done.isCompleted) {
        done.complete(null);
      }
    },
  );

  try {
    return await done.future.timeout(const Duration(seconds: 3));
  } on TimeoutException {
    return null;
  } finally {
    socket.destroy();
  }
}

final class _Observed {
  _Observed({
    required this.route,
    required this.reachedHandler,
    required this.note,
    required this.contentLengthValues,
    required this.transferEncodingValues,
    required this.contentEncodingValues,
    required this.declaredContentLength,
    required this.bodyBytesRead,
  });

  final String route;
  final bool reachedHandler;
  final String note;
  final List<String> contentLengthValues;
  final List<String> transferEncodingValues;
  final List<String> contentEncodingValues;
  final int declaredContentLength;
  final int bodyBytesRead;
}
