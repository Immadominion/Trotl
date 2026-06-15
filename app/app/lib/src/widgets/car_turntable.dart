import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';
import 'package:throtl/src/widgets/car_sprite.dart';

/// The garage showroom car — the real Kenney GLB rendered **live** and
/// auto-rotating (the design's three.js `CarStage`, in a WebView via
/// `model_viewer_plus`). Truly smooth at any speed, drag to spin, with a real
/// 3D ground shadow. The garage gradient shows through the transparent canvas.
///
/// NOTE: we deliberately do NOT pass [poster] to [ModelViewer]. model_viewer_plus'
/// loop-back proxy resolves the poster as a *relative* request and calls
/// `Uri.parse(src).origin` on the bare asset path (`assets/cars/3d/foo.glb`),
/// which throws "Cannot use origin without a scheme" — flooding the log on every
/// frame. Instead we show the side-sprite ourselves (a Flutter [Image.asset])
/// over the canvas and fade it out once the model has had time to mount.
class CarTurntable extends StatefulWidget {
  const CarTurntable({required this.src, this.poster, super.key});

  /// Self-contained GLB asset (`GameCar.glb`).
  final String src;

  /// Side-sprite asset shown while the model loads (no blank flash).
  final String? poster;

  @override
  State<CarTurntable> createState() => _CarTurntableState();
}

class _CarTurntableState extends State<CarTurntable> {
  bool _showPoster = true;
  Timer? _fade;

  @override
  void initState() {
    super.initState();
    _armPoster();
  }

  @override
  void didUpdateWidget(covariant CarTurntable old) {
    super.didUpdateWidget(old);
    // A new car was selected — show its sprite again, then fade.
    if (old.src != widget.src) {
      setState(() => _showPoster = true);
      _armPoster();
    }
  }

  void _armPoster() {
    _fade?.cancel();
    _fade = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _showPoster = false);
    });
  }

  @override
  void dispose() {
    _fade?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final poster = widget.poster;
    // ON WEB: model_viewer_plus mounts the model in an iframe that loads the
    // <model-viewer> module + resolves the GLB as a relative URL — unreliable on
    // web (the showroom car came up blank). Render the pre-rendered side sprite
    // instead — the same floating [CarSprite] the title/onboarding use — so the
    // garage car ALWAYS shows, sized to fill the turntable bay. (Mobile keeps the
    // live, drag-to-spin 3D turntable below.)
    if (kIsWeb) {
      if (poster == null) return const SizedBox.shrink();
      return LayoutBuilder(
        builder: (context, c) {
          final h = c.maxHeight.isFinite && c.maxHeight > 0 ? c.maxHeight : 240.0;
          return Center(child: CarSprite(asset: poster, height: h, widthFactor: 0.92));
        },
      );
    }
    // webview_flutter has no implementation under `flutter test`, so the live
    // viewer can't mount there — fall back to the poster sprite in tests.
    final inTest = WidgetsBinding.instance.runtimeType.toString().contains('Test');
    if (inTest) {
      return poster == null ? const SizedBox.shrink() : Image.asset(poster, fit: BoxFit.contain);
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        ModelViewer(
          // rebuild the viewer when the selected car changes
          key: ValueKey(widget.src),
          src: widget.src,
          // poster intentionally omitted — see the class note.
          alt: 'Showroom car',
          // gentle continuous showroom spin + drag-to-rotate
          autoRotate: true,
          autoRotateDelay: 0,
          rotationPerSecond: '26deg',
          disableZoom: true,
          disablePan: true,
          interactionPrompt: InteractionPrompt.none,
          // elevated 3/4 framing matching the reference turntable camera
          cameraOrbit: '0deg 68deg 105%',
          cameraTarget: '0m 0.35m 0m',
          fieldOfView: '32deg',
          // a soft real ground shadow under the car
          shadowIntensity: 1,
          shadowSoftness: 1,
          // hide model-viewer's default loading bar (the grey line that flashed
          // across on load) + any scrollbars; keep the canvas transparent
          relatedCss:
              'model-viewer::part(default-progress-bar){display:none !important;} '
              '::-webkit-scrollbar{display:none !important;} '
              'html,body{overflow:hidden !important;background:transparent !important;}',
        ),
        // The Flutter-side loading placeholder (the crash-free poster): the side
        // sprite over the canvas, fading out once the GLB has had time to mount.
        // IgnorePointer so it never eats the drag-to-spin gesture.
        if (poster != null)
          IgnorePointer(
            child: AnimatedOpacity(
              opacity: _showPoster ? 1 : 0,
              duration: const Duration(milliseconds: 450),
              child: Image.asset(poster, fit: BoxFit.contain),
            ),
          ),
      ],
    );
  }
}
