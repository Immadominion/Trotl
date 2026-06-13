/// throtl-engine instruction encoders + PDA derivation. Account orders and discriminators are
/// taken verbatim from the generated IDL; the delegation PDA seeds (`buffer` under the owner program,
/// `delegation` / `delegation-metadata` under the DLP) are verified against
/// magicblock-delegation-program-api 3.0.0.
library;

import 'package:meta/meta.dart';
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';
import 'package:throtl_chain/src/codec.dart';

// ── program ids ──────────────────────────────────────────────────────────────
const String throtlEngineProgramId = 'YSaqfuc753DkHZoaEvdNMSTQTf4hEuTtP65hszuvJy9';
const String delegationProgramId = 'DELeGGvXpWV2fqJUhqcF5ZSYMS4JTLjteaAMARRSaeSh';
const String oracleProgramId = 'PriCems5tHihc6UDXDjzjeawomAwBduWMGAi8ZUjppd';
const String magicProgramId = 'Magic11111111111111111111111111111111111111';
const String systemProgramId = '11111111111111111111111111111111';

// ── instruction discriminators (from target/idl/throtl_engine.json) ────────
const List<int> _initRide = [105, 93, 93, 113, 45, 198, 67, 138];
const List<int> _delegateRide = [120, 181, 14, 35, 87, 76, 219, 155];
const List<int> _tick = [92, 79, 44, 8, 101, 80, 63, 15];
const List<int> _flatten = [168, 198, 178, 236, 15, 112, 146, 10];
const List<int> _freeze = [255, 91, 207, 84, 251, 194, 254, 63];
const List<int> _requestSettle = [90, 16, 38, 40, 222, 168, 193, 70];
const List<int> _closeRide = [200, 238, 85, 191, 109, 87, 100, 89];

@immutable
class ThrotlProgram {
  ThrotlProgram({String programId = throtlEngineProgramId})
    : id = Ed25519HDPublicKey.fromBase58(programId);

  final Ed25519HDPublicKey id;

  Ed25519HDPublicKey get _dlp => Ed25519HDPublicKey.fromBase58(delegationProgramId);
  Ed25519HDPublicKey get _system => Ed25519HDPublicKey.fromBase58(systemProgramId);
  Ed25519HDPublicKey get _magic => Ed25519HDPublicKey.fromBase58(magicProgramId);

  // ── PDAs ───────────────────────────────────────────────────────────────────

  /// `["ride", owner, session_id_le]` under throtl-engine.
  Future<Ed25519HDPublicKey> rideSession(Ed25519HDPublicKey owner, int sessionId) =>
      Ed25519HDPublicKey.findProgramAddress(
        seeds: [_ascii('ride'), owner.bytes, u64le(sessionId)],
        programId: id,
      );

  /// `["buffer", ride]` under the OWNER program (throtl-engine).
  Future<Ed25519HDPublicKey> delegateBuffer(Ed25519HDPublicKey ride) =>
      Ed25519HDPublicKey.findProgramAddress(seeds: [_ascii('buffer'), ride.bytes], programId: id);

  /// `["delegation", ride]` under the DLP.
  Future<Ed25519HDPublicKey> delegationRecord(Ed25519HDPublicKey ride) =>
      Ed25519HDPublicKey.findProgramAddress(
        seeds: [_ascii('delegation'), ride.bytes],
        programId: _dlp,
      );

  /// `["delegation-metadata", ride]` under the DLP.
  Future<Ed25519HDPublicKey> delegationMetadata(Ed25519HDPublicKey ride) =>
      Ed25519HDPublicKey.findProgramAddress(
        seeds: [_ascii('delegation-metadata'), ride.bytes],
        programId: _dlp,
      );

  // ── instructions ─────────────────────────────────────────────────────────────

  /// L1: create the ride session PDA (status = Armed).
  Future<Instruction> initRide({
    required Ed25519HDPublicKey owner,
    required int sessionId,
    required Ed25519HDPublicKey sessionKey,
    required int marketId,
    required List<int> feedId, // 32 bytes
    required int gripMode,
    required int fuelUsd6,
    required int maxLevBps,
    required int lossFloor6,
    required int expiresAt,
  }) async {
    assert(feedId.length == 32, 'feed_id must be 32 bytes');
    final ride = await rideSession(owner, sessionId);
    final data = <int>[
      ..._initRide,
      ...u64le(sessionId),
      ...sessionKey.bytes,
      ...u16le(marketId),
      ...feedId,
      gripMode,
      ...u64le(fuelUsd6),
      ...u32le(maxLevBps),
      ...i64le(lossFloor6),
      ...i64le(expiresAt),
    ];
    return Instruction(
      programId: id,
      accounts: [
        AccountMeta.writeable(pubKey: ride, isSigner: false),
        AccountMeta.writeable(pubKey: owner, isSigner: true),
        AccountMeta.readonly(pubKey: _system, isSigner: false),
      ],
      data: ByteArray(data),
    );
  }

  /// L1: delegate the ride PDA to the ER. `validator` (optional) is passed as the first remaining
  /// account so the SDK targets a specific ER node.
  Future<Instruction> delegateRide({
    required Ed25519HDPublicKey owner,
    required int sessionId,
    required int commitFrequencyMs,
    Ed25519HDPublicKey? validator,
  }) async {
    final ride = await rideSession(owner, sessionId);
    final buffer = await delegateBuffer(ride);
    final record = await delegationRecord(ride);
    final metadata = await delegationMetadata(ride);
    final data = <int>[..._delegateRide, ...u64le(sessionId), ...u32le(commitFrequencyMs)];
    return Instruction(
      programId: id,
      accounts: [
        AccountMeta.writeable(pubKey: owner, isSigner: true),
        AccountMeta.writeable(pubKey: buffer, isSigner: false),
        AccountMeta.writeable(pubKey: record, isSigner: false),
        AccountMeta.writeable(pubKey: metadata, isSigner: false),
        AccountMeta.writeable(pubKey: ride, isSigner: false),
        AccountMeta.readonly(pubKey: id, isSigner: false), // owner_program
        AccountMeta.readonly(pubKey: _dlp, isSigner: false),
        AccountMeta.readonly(pubKey: _system, isSigner: false),
        if (validator != null) AccountMeta.readonly(pubKey: validator, isSigner: false),
      ],
      data: ByteArray(data),
    );
  }

  /// ER (session-signed): move virtual exposure toward `targetExpBps`.
  Instruction tick({
    required Ed25519HDPublicKey ride,
    required Ed25519HDPublicKey priceFeed,
    required Ed25519HDPublicKey sessionSigner,
    required int targetExpBps,
  }) => _tickLike(_tick, ride, priceFeed, sessionSigner, i32le(targetExpBps));

  /// ER: flatten (target 0).
  Instruction flatten({
    required Ed25519HDPublicKey ride,
    required Ed25519HDPublicKey priceFeed,
    required Ed25519HDPublicKey sessionSigner,
  }) => _tickLike(_flatten, ride, priceFeed, sessionSigner, const []);

  Instruction _tickLike(
    List<int> disc,
    Ed25519HDPublicKey ride,
    Ed25519HDPublicKey priceFeed,
    Ed25519HDPublicKey sessionSigner,
    List<int> args,
  ) => Instruction(
    programId: id,
    accounts: [
      AccountMeta.writeable(pubKey: ride, isSigner: false),
      AccountMeta.readonly(pubKey: priceFeed, isSigner: false),
      AccountMeta.readonly(pubKey: sessionSigner, isSigner: true),
    ],
    data: ByteArray([...disc, ...args]),
  );

  /// ER: guardian freeze (owner or session key authority).
  Instruction freeze({required Ed25519HDPublicKey ride, required Ed25519HDPublicKey authority}) =>
      Instruction(
        programId: id,
        accounts: [
          AccountMeta.writeable(pubKey: ride, isSigner: false),
          AccountMeta.readonly(pubKey: authority, isSigner: true),
        ],
        data: ByteArray(_freeze),
      );

  /// ER: commit + undelegate. `magicContext` is the commit-context account injected by the
  /// on-chain `commit` macro.
  Instruction requestSettle({
    required Ed25519HDPublicKey payer,
    required Ed25519HDPublicKey ride,
    required Ed25519HDPublicKey magicContext,
  }) => Instruction(
    programId: id,
    accounts: [
      AccountMeta.writeable(pubKey: payer, isSigner: true),
      AccountMeta.writeable(pubKey: ride, isSigner: false),
      AccountMeta.readonly(pubKey: _magic, isSigner: false),
      AccountMeta.writeable(pubKey: magicContext, isSigner: false),
    ],
    data: ByteArray(_requestSettle),
  );

  /// L1: close the ride PDA after undelegation (rent → owner).
  Instruction closeRide({required Ed25519HDPublicKey ride, required Ed25519HDPublicKey owner}) =>
      Instruction(
        programId: id,
        accounts: [
          AccountMeta.writeable(pubKey: ride, isSigner: false),
          AccountMeta.writeable(pubKey: owner, isSigner: true),
        ],
        data: ByteArray(_closeRide),
      );
}

List<int> _ascii(String s) => s.codeUnits;
