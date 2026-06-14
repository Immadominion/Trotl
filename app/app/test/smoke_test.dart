import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:throtl/src/app.dart';
import 'package:throtl/src/theme/theme_controller.dart';
import 'package:throtl/src/wallet/wallet_controller.dart';
import 'package:throtl/src/widgets/chunky.dart';

void main() {
  testWidgets('boots to title, opens connect sheet, rides in practice', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1100);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ThrotlApp(
        themeController: ThemeController(prefs),
        walletController: WalletController(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    // Title screen rendered.
    expect(find.text('THROTL'), findsWidgets);
    expect(find.text('CONNECT WALLET'), findsWidgets);

    // Tap CONNECT WALLET → the connect sheet opens (fixed pumps — the title's
    // bob animation repeats forever, so pumpAndSettle would never settle).
    await tester.tap(find.byType(ChunkyButton).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Continue in practice'), findsOneWidget);

    // Continue in practice (no wallet on the test host) → Garage.
    await tester.tap(find.text('Continue in practice'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('START RACE'), findsWidgets);
  });
}
