/// Turning a presented bearer into §7's grant, from the credentials this server issues.
///
/// ## Why this is separate from `PairingService`
///
/// `PairingService` already implements [ControlAuthenticator] for *session* tokens. A task
/// access token is a different credential with a different scope: §7 binds it to one transfer,
/// and `AGENTS.md` §5 requires the operation direction to be verified on every file request.
/// Folding both into one class would mean one `authenticate` with two very different answers,
/// and the authoriser's scope checks would lose the thing they depend on - which kind of
/// credential arrived.
///
/// The direction comes from the task itself rather than from the token, because that is where
/// §7 keeps it: the direction is a property of the transfer, and a token that named its own
/// direction could claim one the task does not have.
///
/// ## What is deliberately absent
///
/// Nothing here accepts a token for a task that has been cancelled or revoked: [revokeAll]
/// deletes the rows, so the lookup simply fails. There is no "grace period" to get wrong.
library;

import 'package:nearsend/core/network/control_authorization.dart';
import 'package:nearsend/core/protocol/transfer_direction.dart';
import 'package:nearsend/core/storage/task_credential_repository.dart';
import 'package:nearsend/core/storage/transfer_repository.dart';

/// Authenticates a task access token or a restricted completion-query credential.
class TaskTokenAuthenticator implements ControlAuthenticator {
  TaskTokenAuthenticator({required this.credentials, required this.transfers});

  /// The issued-credential store. Only digests and expiry are consulted.
  final TaskCredentialRepository credentials;

  /// Reads the transfer's direction, which §7 makes a property of the task.
  final TransferRepository transfers;

  @override
  ControlGrant? authenticate({required String token, required int nowMillis}) {
    final TaskAccessLookup? access = credentials.lookupTaskAccess(token);
    if (access != null) {
      final TransferDirection? direction = _directionOf(access.transferId);
      if (direction == null) {
        // A transfer whose direction this build cannot read is one it must not act for: a
        // grant with no direction would sail past every caller that checks one.
        return null;
      }
      return TaskGrant(transferId: access.transferId, direction: direction);
    }

    final TaskAccessLookup? completion = credentials.lookupCompletionQuery(
      token,
    );
    if (completion != null) {
      return CompletionQueryGrant(transferId: completion.transferId);
    }

    return null;
  }

  TransferDirection? _directionOf(String transferId) {
    final TransferDeclaration? declaration = transfers.readDeclaration(
      transferId,
    );
    if (declaration == null) {
      return null;
    }
    return TransferDirection.fromWireValue(declaration.direction);
  }
}

/// Tries several authenticators in order, accepting the first grant.
///
/// Needed because a server issues two kinds of bearer - §3's session token and §7's task access
/// token - and the pipeline takes one authenticator. Composing them here rather than branching
/// inside the authoriser keeps the authoriser's job to "what does §7 require", which is a
/// property of the route and not of which credentials exist.
///
/// Order matters only for which grant a token that somehow satisfied two ways would produce;
/// the tokens are 256-bit random values from independent stores, so no token satisfies two.
class ChainedAuthenticator implements ControlAuthenticator {
  const ChainedAuthenticator(this.authenticators);

  final List<ControlAuthenticator> authenticators;

  @override
  ControlGrant? authenticate({required String token, required int nowMillis}) {
    for (final ControlAuthenticator authenticator in authenticators) {
      final ControlGrant? grant = authenticator.authenticate(
        token: token,
        nowMillis: nowMillis,
      );
      if (grant != null) {
        return grant;
      }
    }
    return null;
  }
}
