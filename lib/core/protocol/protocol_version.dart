/// Protocol version and capability negotiation, `docs/protocol/v1.0-draft1.md` §3,
/// and `docs/跨平台离线文件互传系统技术方案_V2.1.md` §17.1.
///
/// The rules being implemented:
///
/// * a **major** version difference is refused outright;
/// * a **minor** difference continues only when the capabilities both sides share
///   cover what the task needs;
/// * an updated client must never silently change an already frozen task's manifest,
///   chunk size or digest rules.
///
/// ## What this file deliberately does not contain
///
/// The draft writes the capability list as `capabilities:[...]` (§3) without
/// enumerating a single capability identifier, and §17.1 speaks of "the capabilities
/// a task needs" without defining them. `AGENTS.md` §3 forbids settling an unresolved
/// protocol detail by preference, so this file implements the **algorithm** and a
/// bounded value type, and does **not** invent a vocabulary. The gap is registered in
/// `docs/PROJECT_LEDGER.md` §5 and must be closed before the protocol is frozen.
///
/// The consequence is honest and testable: negotiation is fully exercisable with any
/// identifiers, and the vocabulary remains a maintainer decision.
library;

import 'dart:convert';

import 'package:nearsend/core/protocol/protocol_exception.dart';
import 'package:nearsend/core/protocol/protocol_limits.dart';

/// A protocol major/minor pair.
class ProtocolVersion implements Comparable<ProtocolVersion> {
  const ProtocolVersion(this.major, this.minor);

  /// The version this build implements.
  static const ProtocolVersion current = ProtocolVersion(
    ProtocolLimits.protocolMajor,
    ProtocolLimits.protocolMinor,
  );

  final int major;
  final int minor;

  /// Parses `{protocolMajor, protocolMinor}` from a negotiated body.
  factory ProtocolVersion.fromJson(Map<String, Object?> json, String scope) {
    final Object? major = json['protocolMajor'];
    final Object? minor = json['protocolMinor'];
    if (major is! int || minor is! int) {
      throw ProtocolViolation(
        ProtocolErrorCode.invalidField,
        '$scope must carry integer protocolMajor and protocolMinor',
      );
    }
    if (major < 0 || minor < 0) {
      throw ProtocolViolation(
        ProtocolErrorCode.invalidField,
        '$scope protocol version must not be negative',
      );
    }
    return ProtocolVersion(major, minor);
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'protocolMajor': major,
    'protocolMinor': minor,
  };

  @override
  int compareTo(ProtocolVersion other) {
    final int byMajor = major.compareTo(other.major);
    return byMajor != 0 ? byMajor : minor.compareTo(other.minor);
  }

  @override
  bool operator ==(Object other) =>
      other is ProtocolVersion && other.major == major && other.minor == minor;

  /// Ordering operators, so a version can be compared without a raw [compareTo].
  bool operator >(ProtocolVersion other) => compareTo(other) > 0;
  bool operator <(ProtocolVersion other) => compareTo(other) < 0;
  bool operator >=(ProtocolVersion other) => compareTo(other) >= 0;
  bool operator <=(ProtocolVersion other) => compareTo(other) <= 0;

  @override
  int get hashCode => Object.hash(major, minor);

  @override
  String toString() => '$major.$minor';
}

/// A capability identifier as it appears in a `capabilities` array.
///
/// Only bounds are enforced here (printable ASCII, 1..64 bytes). Imposing a grammar
/// would be inventing protocol detail; the draft defines neither a grammar nor a
/// vocabulary.
class Capability {
  const Capability._(this.id);

  /// The longest identifier the draft's 1 MiB control body comfortably allows for a
  /// single entry. A project decision, not a spec value, and documented as such.
  static const int maxIdBytes = 64;

  final String id;

  /// Validates and wraps an identifier.
  static Capability parse(Object? value) {
    if (value is! String) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'a capability identifier must be a string',
      );
    }
    if (value.isEmpty) {
      throw const ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'a capability identifier must not be empty',
      );
    }
    final int byteLength = utf8.encode(value).length;
    if (byteLength > maxIdBytes) {
      throw ProtocolViolation(
        ProtocolErrorCode.invalidField,
        'a capability identifier must be at most $maxIdBytes UTF-8 bytes',
      );
    }
    for (final int unit in value.codeUnits) {
      if (unit < 0x21 || unit > 0x7E) {
        throw const ProtocolViolation(
          ProtocolErrorCode.invalidField,
          'a capability identifier must be printable ASCII without spaces',
        );
      }
    }
    return Capability._(value);
  }

  @override
  bool operator ==(Object other) => other is Capability && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => id;
}

/// An unordered, duplicate-free set of capabilities.
class CapabilitySet {
  CapabilitySet(Iterable<Capability> capabilities)
    : _byId = <String, Capability>{
        for (final Capability capability in capabilities)
          capability.id: capability,
      };

  /// Parses a `capabilities` array, rejecting malformed entries and duplicates.
  ///
  /// Duplicates are rejected rather than folded away: §4 rejects input that does not
  /// match the specification, and a repeated entry is a peer inconsistency worth
  /// surfacing rather than silently normalising.
  factory CapabilitySet.fromJson(Object? json, String scope) {
    if (json is! List) {
      throw ProtocolViolation(
        ProtocolErrorCode.invalidField,
        '$scope.capabilities must be an array',
      );
    }
    final List<Capability> parsed = <Capability>[];
    final Set<String> seen = <String>{};
    for (int i = 0; i < json.length; i++) {
      final Capability capability = Capability.parse(json[i]);
      if (!seen.add(capability.id)) {
        throw ProtocolViolation(
          ProtocolErrorCode.invalidField,
          '$scope.capabilities repeats "${capability.id}"',
        );
      }
      parsed.add(capability);
    }
    return CapabilitySet(parsed);
  }

  final Map<String, Capability> _byId;

  bool get isEmpty => _byId.isEmpty;

  int get length => _byId.length;

  Iterable<Capability> get capabilities => _byId.values;

  Set<String> get ids => _byId.keys.toSet();

  bool contains(Capability capability) => _byId.containsKey(capability.id);

  bool containsId(String id) => _byId.containsKey(id);

  /// Capabilities present on both sides.
  CapabilitySet intersection(CapabilitySet other) =>
      CapabilitySet(capabilities.where((Capability c) => other.contains(c)));

  /// Sorted identifiers, for stable serialisation and readable assertions.
  List<String> toJson() => _byId.keys.toList()..sort();

  @override
  String toString() => 'CapabilitySet(${toJson().join(', ')})';
}

/// Why negotiation failed.
enum NegotiationFailure {
  /// The peers implement different protocol majors.
  majorVersionMismatch,

  /// The shared capabilities do not cover what the task requires.
  missingCapabilities,
}

/// The result of negotiating a session or task.
class NegotiationOutcome {
  const NegotiationOutcome._({
    required this.accepted,
    required this.agreedVersion,
    required this.shared,
    this.failure,
    this.missing = const <String>[],
  });

  /// Negotiation succeeded; proceed with [agreedVersion].
  factory NegotiationOutcome.accepted({
    required ProtocolVersion agreedVersion,
    required CapabilitySet shared,
  }) => NegotiationOutcome._(
    accepted: true,
    agreedVersion: agreedVersion,
    shared: shared,
  );

  /// Negotiation failed; do not proceed, and do not transfer any bytes.
  factory NegotiationOutcome.rejected({
    required NegotiationFailure failure,
    required ProtocolVersion agreedVersion,
    required CapabilitySet shared,
    List<String> missing = const <String>[],
  }) => NegotiationOutcome._(
    accepted: false,
    agreedVersion: agreedVersion,
    shared: shared,
    failure: failure,
    missing: missing,
  );

  final bool accepted;

  /// The version to use. On rejection this is not usable for data transfer; it is
  /// reported so the caller can log what was compared.
  final ProtocolVersion agreedVersion;

  /// Capabilities both sides advertised.
  final CapabilitySet shared;

  final NegotiationFailure? failure;

  /// Required capabilities that were not shared. Empty unless [failure] is
  /// [NegotiationFailure.missingCapabilities].
  final List<String> missing;

  /// The protocol error code to answer a rejection with.
  ProtocolErrorCode? get errorCode {
    switch (failure) {
      case NegotiationFailure.majorVersionMismatch:
        // A major difference is a version problem, and §11 maps version problems to
        // INVALID_FIELD at the request level.
        return ProtocolErrorCode.invalidField;
      case NegotiationFailure.missingCapabilities:
        return ProtocolErrorCode.invalidField;
      case null:
        return null;
    }
  }

  @override
  String toString() => accepted
      ? 'accepted($agreedVersion, shared=${shared.ids.length})'
      : 'rejected(${failure?.name}, missing=$missing)';
}

/// The negotiation algorithm from §17.1.
abstract final class ProtocolNegotiation {
  /// Negotiates a version and capability agreement.
  ///
  /// [requiredCapabilities] are the capabilities *this task* needs; an empty set
  /// means the task has no capability requirements, which is the correct reading for
  /// a plain single-file transfer today.
  ///
  /// The agreed minor version is the **lower** of the two. §17.1 does not name a
  /// resolution rule, and taking the lower value is the conservative one: the peer may
  /// not implement whatever a higher minor introduced. This interpretation is
  /// recorded in the ledger as something to confirm when the protocol is frozen.
  static NegotiationOutcome negotiate({
    required ProtocolVersion local,
    required CapabilitySet localCapabilities,
    required ProtocolVersion remote,
    required CapabilitySet remoteCapabilities,
    Set<String> requiredCapabilities = const <String>{},
  }) {
    final CapabilitySet shared = localCapabilities.intersection(
      remoteCapabilities,
    );
    final ProtocolVersion agreed = ProtocolVersion(
      local.major,
      local.minor < remote.minor ? local.minor : remote.minor,
    );

    if (local.major != remote.major) {
      return NegotiationOutcome.rejected(
        failure: NegotiationFailure.majorVersionMismatch,
        agreedVersion: agreed,
        shared: shared,
      );
    }

    final List<String> missing =
        requiredCapabilities
            .where((String id) => !shared.containsId(id))
            .toList()
          ..sort();

    if (missing.isNotEmpty) {
      return NegotiationOutcome.rejected(
        failure: NegotiationFailure.missingCapabilities,
        agreedVersion: agreed,
        shared: shared,
        missing: missing,
      );
    }

    return NegotiationOutcome.accepted(agreedVersion: agreed, shared: shared);
  }

  /// Whether an update may alter an already frozen task.
  ///
  /// §17.1: an updated client must not automatically change a frozen task's manifest,
  /// chunk size or digest rules. This predicate exists so that rule has one
  /// implementation rather than being re-derived at each call site.
  static bool mayModifyFrozenTask({
    required ProtocolVersion frozenWith,
    required int frozenChunkSizeBytes,
    required ProtocolVersion now,
    required int currentChunkSizeBytes,
  }) {
    return frozenWith == now && frozenChunkSizeBytes == currentChunkSizeBytes;
  }
}
