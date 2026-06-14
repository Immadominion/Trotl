import 'package:flutter/widgets.dart';

/// The chunky cartoon palette, ported verbatim from the design system (`G`)
/// in the handoff. One [ThrotlPalette] is active at a time; switching themes
/// swaps the whole palette (see the 6 brand themes in [kThemes]).
@immutable
class ThrotlPalette {
  const ThrotlPalette({
    required this.key,
    required this.label,
    required this.skyTop,
    required this.skyBot,
    required this.carAsset,
    required this.tint,
    required this.ink,
    required this.inkSoft,
    required this.cream,
    required this.creamDim,
    required this.paper,
    required this.blueTop,
    required this.blueBot,
    required this.blueDeep,
    required this.yellow,
    required this.orange,
    required this.orangeDeep,
    required this.green,
    required this.greenDeep,
    required this.red,
    required this.redDeep,
    required this.purple,
    required this.cyan,
    required this.white,
  });

  final String key;
  final String label;

  /// Settings-swatch sky gradient (top, bottom).
  final Color skyTop;
  final Color skyBot;

  /// Signature car + livery tint this theme arrives with.
  final String carAsset;
  final Color tint;

  final Color ink;
  final Color inkSoft;
  final Color cream;
  final Color creamDim;
  final Color paper;

  /// Screen background gradient (top → bottom → deep).
  final Color blueTop;
  final Color blueBot;
  final Color blueDeep;

  final Color yellow;
  final Color orange;
  final Color orangeDeep;
  final Color green;
  final Color greenDeep;
  final Color red;
  final Color redDeep;
  final Color purple;
  final Color cyan;
  final Color white;

  ThrotlPalette copyWith({
    String? key,
    String? label,
    Color? skyTop,
    Color? skyBot,
    String? carAsset,
    Color? tint,
    Color? ink,
    Color? inkSoft,
    Color? cream,
    Color? creamDim,
    Color? paper,
    Color? blueTop,
    Color? blueBot,
    Color? blueDeep,
    Color? yellow,
    Color? orange,
    Color? orangeDeep,
    Color? green,
    Color? greenDeep,
    Color? red,
    Color? redDeep,
    Color? purple,
    Color? cyan,
    Color? white,
  }) {
    return ThrotlPalette(
      key: key ?? this.key,
      label: label ?? this.label,
      skyTop: skyTop ?? this.skyTop,
      skyBot: skyBot ?? this.skyBot,
      carAsset: carAsset ?? this.carAsset,
      tint: tint ?? this.tint,
      ink: ink ?? this.ink,
      inkSoft: inkSoft ?? this.inkSoft,
      cream: cream ?? this.cream,
      creamDim: creamDim ?? this.creamDim,
      paper: paper ?? this.paper,
      blueTop: blueTop ?? this.blueTop,
      blueBot: blueBot ?? this.blueBot,
      blueDeep: blueDeep ?? this.blueDeep,
      yellow: yellow ?? this.yellow,
      orange: orange ?? this.orange,
      orangeDeep: orangeDeep ?? this.orangeDeep,
      green: green ?? this.green,
      greenDeep: greenDeep ?? this.greenDeep,
      red: red ?? this.red,
      redDeep: redDeep ?? this.redDeep,
      purple: purple ?? this.purple,
      cyan: cyan ?? this.cyan,
      white: white ?? this.white,
    );
  }
}

/// A selectable car — a real Kenney car-kit GLB. A tight side view (`side`,
/// pre-rendered) drives the race / results / share, while the garage showroom
/// renders the live `glb` and auto-rotates it. Replaces the old flat 64px
/// previews — this is the design's three.js GLB, served live so it
/// stays pixel-perfect and 60fps everywhere.
@immutable
class GameCar {
  const GameCar({
    required this.key,
    required this.name,
    required this.sideAspect,
    required this.sideScale,
  });

  /// Asset key (e.g. `race`) — names the rendered sprite files.
  final String key;
  final String name;

  /// width / height of the side sprite (varies per model: an F1 is long+low,
  /// a kart is short+tall). Lets the scene size the car without distortion.
  final double sideAspect;

  /// Relative on-road size, normalised to the race car (= 1.0). All sides were
  /// rendered at one 3D scale, so this keeps a kart smaller than a truck.
  final double sideScale;

  /// Tight side view — wheels on the bottom edge. Used on the road.
  String get side => 'assets/cars/side/$key.png';

  /// Self-contained GLB (embedded colormap) — the live garage turntable.
  String get glb => 'assets/cars/3d/$key.glb';

  /// Back-compat alias — most screens just want the side sprite.
  String get asset => side;
}

const List<GameCar> kCars = [
  GameCar(key: 'race', name: 'Race-1', sideAspect: 2.958, sideScale: 1),
  GameCar(key: 'race-future', name: 'Phantom GT', sideAspect: 2.882, sideScale: 1.035),
  GameCar(key: 'hatchback-sports', name: 'Street Spec', sideAspect: 2.351, sideScale: 0.992),
  GameCar(key: 'sedan-sports', name: 'Sedan RS', sideAspect: 2.118, sideScale: 0.970),
  GameCar(key: 'kart-oobi', name: 'Pit Kart', sideAspect: 1.285, sideScale: 0.776),
  GameCar(key: 'police', name: 'Interceptor', sideAspect: 2.192, sideScale: 0.967),
  GameCar(key: 'taxi', name: 'Checker', sideAspect: 1.721, sideScale: 0.914),
  GameCar(key: 'sedan', name: 'Commuter', sideAspect: 1.806, sideScale: 0.918),
  GameCar(key: 'suv', name: 'Trailhead', sideAspect: 1.843, sideScale: 0.903),
  GameCar(key: 'suv-luxury', name: 'Executive', sideAspect: 2.039, sideScale: 0.963),
  GameCar(key: 'van', name: 'Hauler', sideAspect: 1.879, sideScale: 0.934),
  GameCar(key: 'ambulance', name: 'Medic', sideAspect: 1.700, sideScale: 0.951),
  GameCar(key: 'firetruck', name: 'Blaze', sideAspect: 1.869, sideScale: 0.980),
  GameCar(key: 'garbage-truck', name: 'Compactor', sideAspect: 1.967, sideScale: 0.957),
];

// Per-theme signature cars — referenced by [ThrotlPalette.carAsset] as a key.
const String _carRace = 'race';
const String _carFuture = 'race-future';
const String _carHatch = 'hatchback-sports';

/// Arcade — the default blue theme (the base `G` tokens).
const ThrotlPalette kArcade = ThrotlPalette(
  key: 'arcade',
  label: 'Arcade',
  skyTop: Color(0xFF3E8BFF),
  skyBot: Color(0xFF2049C9),
  carAsset: _carRace,
  tint: Color(0xFFFF5A5A),
  ink: Color(0xFF23203A),
  inkSoft: Color(0xFF3A3656),
  cream: Color(0xFFFFF8EC),
  creamDim: Color(0xFFF3E9D2),
  paper: Color(0xFFFFF4E3),
  blueTop: Color(0xFF3E8BFF),
  blueBot: Color(0xFF2049C9),
  blueDeep: Color(0xFF16307E),
  yellow: Color(0xFFFFC421),
  orange: Color(0xFFFF8E1F),
  orangeDeep: Color(0xFFE06A00),
  green: Color(0xFF71D63C),
  greenDeep: Color(0xFF3FA51B),
  red: Color(0xFFFF5A5A),
  redDeep: Color(0xFFD62F3F),
  purple: Color(0xFFA06CF8),
  cyan: Color(0xFF4FD9FF),
  white: Color(0xFFFFFFFF),
);

/// The 6 Solana-ecosystem brand themes (Arcade default + 5 brand kits).
final Map<String, ThrotlPalette> kThemes = {
  'arcade': kArcade,
  'jupiter': kArcade.copyWith(
    key: 'jupiter',
    label: 'Jupiter',
    skyTop: const Color(0xFF1C8FB0),
    skyBot: const Color(0xFF0E2230),
    carAsset: _carFuture,
    tint: const Color(0xFFA4D756),
    blueTop: const Color(0xFF1C8FB0),
    blueBot: const Color(0xFF0E2230),
    blueDeep: const Color(0xFF081722),
    yellow: const Color(0xFFC7F284),
    orange: const Color(0xFFA4D756),
    orangeDeep: const Color(0xFF6FA82E),
    green: const Color(0xFFA4D756),
    greenDeep: const Color(0xFF5C9425),
    red: const Color(0xFFFF6B6B),
    redDeep: const Color(0xFFD6453F),
    purple: const Color(0xFF00B6E7),
    cyan: const Color(0xFF22CCEE),
    ink: const Color(0xFF08141C),
    inkSoft: const Color(0xFF163040),
    cream: const Color(0xFFECF7E2),
    creamDim: const Color(0xFFCFE6D6),
    paper: const Color(0xFFE6F4EC),
  ),
  'bonk': kArcade.copyWith(
    key: 'bonk',
    label: 'BONK',
    skyTop: const Color(0xFFFFB838),
    skyBot: const Color(0xFFFC8E03),
    carAsset: _carHatch,
    tint: const Color(0xFFFF8E1F),
    blueTop: const Color(0xFFFFB838),
    blueBot: const Color(0xFFFC8E03),
    blueDeep: const Color(0xFFB85E00),
    yellow: const Color(0xFFFFE208),
    orange: const Color(0xFFFF5C01),
    orangeDeep: const Color(0xFFC23F00),
    red: const Color(0xFFFF0000),
    redDeep: const Color(0xFFC20000),
    purple: const Color(0xFFFDC202),
    cyan: const Color(0xFFFFD110),
    ink: const Color(0xFF241405),
    inkSoft: const Color(0xFF402510),
    cream: const Color(0xFFFFF6E0),
    creamDim: const Color(0xFFFBE6B8),
    paper: const Color(0xFFFFF3D6),
  ),
  'monke': kArcade.copyWith(
    key: 'monke',
    label: 'MonkeDAO',
    skyTop: const Color(0xFF1F8A4D),
    skyBot: const Color(0xFF0E3A23),
    carAsset: _carHatch,
    tint: const Color(0xFF71D63C),
    blueTop: const Color(0xFF1F8A4D),
    blueBot: const Color(0xFF0E3A23),
    blueDeep: const Color(0xFF072617),
    yellow: const Color(0xFFFFD23F),
    orange: const Color(0xFFFFB200),
    orangeDeep: const Color(0xFFD98A00),
    green: const Color(0xFF7BE06A),
    red: const Color(0xFFFF6B5A),
    redDeep: const Color(0xFFD6453F),
    purple: const Color(0xFF36B36B),
    cyan: const Color(0xFF9BE8B0),
    ink: const Color(0xFF082417),
    inkSoft: const Color(0xFF163A28),
    cream: const Color(0xFFF4F6E2),
    creamDim: const Color(0xFFDDE8C2),
    paper: const Color(0xFFEEF4DC),
  ),
  'madlads': kArcade.copyWith(
    key: 'madlads',
    label: 'Mad Lads',
    skyTop: const Color(0xFF2A2622),
    skyBot: const Color(0xFF121010),
    carAsset: _carRace,
    tint: const Color(0xFFF5402C),
    blueTop: const Color(0xFF2A2622),
    blueBot: const Color(0xFF121010),
    blueDeep: const Color(0xFF0A0807),
    yellow: const Color(0xFFF5C84B),
    orange: const Color(0xFFF5402C),
    orangeDeep: const Color(0xFFB82A1B),
    green: const Color(0xFF7BD06A),
    red: const Color(0xFFF5402C),
    redDeep: const Color(0xFFB82A1B),
    purple: const Color(0xFFE0C39A),
    cyan: const Color(0xFFEDE3D0),
    ink: const Color(0xFF0A0807),
    inkSoft: const Color(0xFF2A2622),
    cream: const Color(0xFFEDE3D0),
    creamDim: const Color(0xFFD6C9B0),
    paper: const Color(0xFFE8DCC6),
  ),
  'solflare': kArcade.copyWith(
    key: 'solflare',
    label: 'Solflare',
    skyTop: const Color(0xFFFFB23E),
    skyBot: const Color(0xFF5B2A8C),
    carAsset: _carFuture,
    tint: const Color(0xFFFC7227),
    blueTop: const Color(0xFFFFB23E),
    blueBot: const Color(0xFF7A3A8C),
    blueDeep: const Color(0xFF3A1A5C),
    yellow: const Color(0xFFFFC93C),
    orange: const Color(0xFFFC7227),
    orangeDeep: const Color(0xFFD9531A),
    green: const Color(0xFF5BD6A0),
    greenDeep: const Color(0xFF2FA576),
    red: const Color(0xFFFF6B6B),
    redDeep: const Color(0xFFD6453F),
    purple: const Color(0xFF9A5CF6),
    cyan: const Color(0xFFFFC93C),
    ink: const Color(0xFF241433),
    inkSoft: const Color(0xFF3A2450),
    cream: const Color(0xFFFFF3E0),
    creamDim: const Color(0xFFFBE0C0),
    paper: const Color(0xFFFFF0D8),
  ),
};

const List<String> kThemeOrder = [
  'arcade',
  'jupiter',
  'bonk',
  'monke',
  'madlads',
  'solflare',
];

/// `gShade` from the design: [f] < 0 darkens toward black by |f|, [f] > 0
/// lightens toward white by f. Used for bevel gradients + pressed states.
Color shade(Color c, double f) {
  int ch(double channel01) {
    final s = channel01 * 255.0;
    final v = f > 0 ? s + (255.0 - s) * f : s + s * f;
    return v.round().clamp(0, 255);
  }

  return Color.fromARGB((c.a * 255).round(), ch(c.r), ch(c.g), ch(c.b));
}

/// Display (Lilita One) + body (Baloo 2) font families — bundled offline.
const String kFontDisplay = 'Lilita One';
const String kFontBody = 'Baloo 2';
