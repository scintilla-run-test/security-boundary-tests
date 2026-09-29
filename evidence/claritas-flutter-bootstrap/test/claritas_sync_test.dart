import 'package:claritas_flutter/claritas_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('revisions compare monotonically', () {
    const ClaritasRevision older = ClaritasRevision(7);
    const ClaritasRevision newer = ClaritasRevision(8);

    expect(older.compareTo(newer), lessThan(0));
    expect(newer.compareTo(older), greaterThan(0));
    expect(const ClaritasRevision(8), newer);
  });

  testWidgets('current status includes the observed revision', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ClaritasSyncStatus(
            state: ClaritasSyncState.current,
            revision: 42,
          ),
        ),
      ),
    );

    expect(find.text('Current · revision 42'), findsOneWidget);
    expect(find.byIcon(Icons.sync), findsOneWidget);
  });

  testWidgets('syncing status exposes bounded progress UI', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ClaritasSyncStatus(state: ClaritasSyncState.syncing),
        ),
      ),
    );

    expect(find.text('Syncing'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('failed status reports the supplied error message', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ClaritasSyncStatus(
            state: ClaritasSyncState.failed,
            errorMessage: 'offline',
          ),
        ),
      ),
    );

    expect(find.text('Sync failed · offline'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
  });
}
