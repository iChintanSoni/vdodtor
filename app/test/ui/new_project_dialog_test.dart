import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/model/project.dart';
import 'package:vdodtor/model/time.dart';
import 'package:vdodtor/ui/new_project_dialog.dart';

void main() {
  late NewProjectRequest? result;
  late bool returned;

  Future<void> openDialog(WidgetTester tester) async {
    result = null;
    returned = false;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                result = await showNewProjectDialog(context);
                returned = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('defaults to 16:9 at 30 fps', (tester) async {
    await openDialog(tester);

    expect(find.text('1920 × 1080'), findsOneWidget);
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(result!.aspect, ProjectAspect.landscape16x9);
    expect(result!.frameRate, FrameRates.fps30);
    expect(result!.name, 'Untitled');
  });

  testWidgets('collects a name, an aspect and a frame rate', (tester) async {
    await openDialog(tester);

    await tester.enterText(find.byType(TextField), 'Holiday');
    await tester.tap(find.text('9:16'));
    await tester.pump();
    await tester.tap(find.text('24 fps'));
    await tester.pump();

    // The dialog answers "what am I about to make?" before the click.
    expect(find.text('1080 × 1920'), findsOneWidget);

    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(result!.name, 'Holiday');
    expect(result!.aspect, ProjectAspect.portrait9x16);
    expect(result!.frameRate, FrameRates.fps24);
    expect(result!.format.width, 1080);
    expect(result!.format.height, 1920);
  });

  testWidgets('every offered aspect and rate is reachable', (tester) async {
    for (final aspect in ProjectAspect.values) {
      for (final rate in FrameRates.offered) {
        await openDialog(tester);
        await tester.tap(find.text(aspect.label));
        await tester.pump();
        await tester.tap(
            find.text('${rate.numerator ~/ rate.denominator} fps'));
        await tester.pump();
        await tester.tap(find.text('Create'));
        await tester.pumpAndSettle();

        expect(result!.aspect, aspect);
        expect(result!.frameRate, rate);
        // The short side is 1080: free-tier resolution, whatever the shape.
        expect(result!.format.shortSide, 1080);
      }
    }
  });

  testWidgets('cancelling makes nothing', (tester) async {
    await openDialog(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(returned, isTrue);
    expect(result, isNull);
  });
}
