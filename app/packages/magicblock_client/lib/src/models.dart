import 'package:meta/meta.dart';

/// An Ephemeral Rollup validator advertised by the Magic Router `getRoutes`.
@immutable
class ErValidator {
  const ErValidator({
    required this.identity,
    required this.fqdn,
    required this.baseFee,
    required this.blockTimeMs,
    required this.countryCode,
  });

  factory ErValidator.fromJson(Map<String, dynamic> j) => ErValidator(
    identity: j['identity'] as String,
    fqdn: (j['fqdn'] as String).trim(),
    baseFee: (j['baseFee'] as num?)?.toInt() ?? 0,
    blockTimeMs: (j['blockTimeMs'] as num?)?.toInt() ?? 0,
    countryCode: j['countryCode'] as String? ?? '',
  );

  /// Validator identity pubkey (also the delegation `authority`). Passed to delegate config.
  final String identity;

  /// Base RPC/WS host of this ER node, e.g. `https://devnet-us.magicblock.app/` (trailing slash).
  final String fqdn;
  final int baseFee;
  final int blockTimeMs;

  /// ISO-3 country code (e.g. USA, DEU, SGP).
  final String countryCode;

  /// `wss://` URL for this node's subscription endpoint (same host as [fqdn]).
  String get wsUrl => fqdn.replaceFirst('https://', 'wss://').replaceFirst(RegExp(r'/$'), '');

  /// HTTP RPC URL without the trailing slash.
  String get rpcUrl => fqdn.replaceFirst(RegExp(r'/$'), '');
}

/// Result of `getDelegationStatus`. The authoritative "where does this account live" — point your
/// ER RPC/WS at [fqdn] when [isDelegated].
@immutable
class DelegationStatus {
  const DelegationStatus({
    required this.isDelegated,
    this.fqdn,
    this.authority,
    this.owner,
    this.delegationSlot,
    this.lamports,
  });

  factory DelegationStatus.fromJson(Map<String, dynamic> j) {
    final rec = j['delegationRecord'] as Map<String, dynamic>?;
    return DelegationStatus(
      isDelegated: j['isDelegated'] as bool? ?? false,
      fqdn: (j['fqdn'] as String?)?.trim(),
      authority: rec?['authority'] as String?,
      owner: rec?['owner'] as String?,
      delegationSlot: (rec?['delegationSlot'] as num?)?.toInt(),
      lamports: (rec?['lamports'] as num?)?.toInt(),
    );
  }

  final bool isDelegated;
  final String? fqdn;
  final String? authority;
  final String? owner;
  final int? delegationSlot;
  final int? lamports;
}

/// `getBlockhashForAccounts` result — an ER-valid blockhash for txs touching delegated accounts.
@immutable
class BlockhashInfo {
  const BlockhashInfo(this.blockhash, this.lastValidBlockHeight);

  factory BlockhashInfo.fromJson(Map<String, dynamic> j) =>
      BlockhashInfo(j['blockhash'] as String, (j['lastValidBlockHeight'] as num).toInt());

  final String blockhash;
  final int lastValidBlockHeight;
}
