import 'package:actionnotes/models/canvas_layout.dart';
import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/ui/canvas_screen.dart';
import 'package:actionnotes/ui/checklist_view.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:actionnotes/ui/touch_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fakes.dart';

/// A canvas on a phone: a finger pans, two fingers zoom.
Future<AppState> pumpTouchCanvas(WidgetTester tester) async {
  TouchInput.debugOverride = true;
  addTearDown(() => TouchInput.debugOverride = null);

  tester.view.physicalSize = const Size(800, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final state = newTestState(FakeLocalStore());
  await state.init();
  await state.createProject('List');
  await state.addBlock('list', 'Board');
  await state.setBlockBody('list', 'Board', '- One');
  await state.setCanvas('list', 'Board', true);
  await state.setCanvasSpots('list', 'Board', const [
    CanvasSpot(x: 200, y: 300, width: 160, ref: 'One'),
  ]);

  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: state,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const ChecklistView(slug: 'list'),
      ),
    ),
  );
  await tester.pumpAndSettle();

  await tester.tap(find.byTooltip('Open full screen'));
  await tester.pumpAndSettle();
  return state;
}

Finder onCanvas(String text) =>
    find.descendant(of: find.byType(CanvasScreen), matching: find.text(text));

void main() {
  testWidgets('pinching over a card zooms and leaves the card where it is', (
    tester,
  ) async {
    final state = await pumpTouchCanvas(tester);
    final card = onCanvas('One');
    final before = state.layoutFor('list').spotsFor('Board').single;
    final centre = tester.getCenter(card);
    final drawnBefore = tester.getSize(card).width;

    // Two fingers on the card itself, spreading apart.
    final one = await tester.startGesture(centre - const Offset(20, 0));
    final two = await tester.startGesture(centre + const Offset(20, 0));
    await tester.pump();

    for (var step = 1; step <= 5; step++) {
      await one.moveTo(centre - Offset(20.0 + step * 12, 0));
      await two.moveTo(centre + Offset(20.0 + step * 12, 0));
      await tester.pump();
    }
    await one.up();
    await two.up();
    await tester.pumpAndSettle();

    // The board zoomed, which is what the pinch meant — the card is drawn
    // bigger without having moved on the board.
    expect(tester.getSize(card).width, greaterThan(drawnBefore));

    final after = state.layoutFor('list').spotsFor('Board').single;
    // Where the card sits on the board is not what a pinch is about, and
    // dragging it about under the fingers is what it used to do.
    expect(after.x, closeTo(before.x, 0.5));
    expect(after.y, closeTo(before.y, 0.5));
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('one finger still moves the card, from where it lands', (
    tester,
  ) async {
    final state = await pumpTouchCanvas(tester);
    final before = state.layoutFor('list').spotsFor('Board').single;

    await tester.drag(onCanvas('One'), const Offset(60, 40));
    await tester.pumpAndSettle();

    final after = state.layoutFor('list').spotsFor('Board').single;
    // The whole sixty pixels, not sixty less the slop the recogniser ate.
    expect(after.x - before.x, closeTo(60, 1));
    expect(after.y - before.y, closeTo(40, 1));
    await tester.pump(const Duration(seconds: 3));
  });
}
