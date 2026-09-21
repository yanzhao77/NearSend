// Dumps a generated identity so an independent implementation can check it.
//
// ADR-0005 requires that the certificate this project generates on first run be verified by
// something that did not generate it: the same bytes must parse with openssl, and the
// fingerprint openssl computes over the DER must equal the pin the QR code would carry.
//
// This writes the **private key to disk**, which `AGENTS.md` §5 forbids anywhere near the
// repository. So the script refuses to write inside the repository at all, and the only
// supported destination is a scratch directory outside it.
//
// Run:
//   dart run tooling/spikes/tls_identity/dump.dart <directory outside the repository>
import 'dart:io';

import 'package:nearsend/core/security/tls_identity.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('usage: dump.dart <directory outside the repository>');
    exit(2);
  }

  final Directory target = Directory(args.single).absolute;
  final Directory repository = Directory.current.absolute;
  if (target.path == repository.path ||
      target.path.startsWith('${repository.path}${Platform.pathSeparator}')) {
    stderr.writeln(
      'refusing to write a private key inside the repository ($repository)',
    );
    exit(2);
  }
  target.createSync(recursive: true);

  final TlsIdentity identity = generateTlsIdentity(
    commonName: 'NearSend',
    subjectAltNames: <String>['127.0.0.1', '192.168.10.100'],
  );

  File('${target.path}${Platform.pathSeparator}cert.pem')
      .writeAsBytesSync(identity.certificatePem);
  File('${target.path}${Platform.pathSeparator}key.pem')
      .writeAsBytesSync(identity.privateKeyPem);

  stdout.writeln('wrote      : ${target.path}');
  stdout.writeln('pin        : ${identity.pin}');
  stdout.writeln('cert bytes : ${identity.certificatePem.length}');
  stdout.writeln('key bytes  : ${identity.privateKeyPem.length}');
}
