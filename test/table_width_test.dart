import 'package:actionnotes/ui/note_blocks_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final width in [1200.0, 360.0]) {
    testWidgets('table fills a $width pane and scrolls when needed',
        (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: Scaffold(
        body: NoteBlocksEditor(
          initialMarkdown: '| One | Two | Three |\n| --- | --- | --- |\n| a | b | c |',
          onChanged: (_) {},
        ),
      )));
      await tester.pumpAndSettle();
      final tableWidth = tester.getSize(find.byType(Table)).width;
      if (width > 760) {
        expect(tableWidth, greaterThan(1100));
        expect(tableWidth, lessThan(width));
      } else {
        expect(tableWidth, 450);
        final scroll = find.byWidgetPredicate((widget) =>
            widget is SingleChildScrollView &&
            widget.scrollDirection == Axis.horizontal);
        await tester.drag(scroll, const Offset(-150, 0));
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(find.byType(Table)).dx, lessThan(0));
      }
      expect(tester.takeException(), isNull);
    });
  }
}
