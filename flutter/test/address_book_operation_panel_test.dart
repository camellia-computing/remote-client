import 'package:camellia_remote_app/common/widgets/address_book_operation_panel.dart';
import 'package:camellia_remote_app/models/address_book_mutations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final pending = PendingAddressBookOperation(
  '03440000-0000-4000-8000-000000000001',
  List.filled(64, 'a').join(),
  1,
);

void main() {
  Widget panel({
    bool busy = false,
    bool ready = true,
    String error = '',
    Future<void> Function(PendingAddressBookOperation)? recover,
    Future<void> Function(PendingAddressBookOperation, String)? reconcile,
  }) => MaterialApp(
    home: Scaffold(
      body: Column(
        children: [
          AddressBookOperationPanel(
            busy: busy,
            ready: ready,
            storageError: error,
            status: '',
            pending: [pending],
            onRefresh: () async {},
            onRecover: recover ?? (_) async {},
            onReconcile: reconcile ?? (_, _) async {},
          ),
          Expanded(
            child: TextButton(
              onPressed: () {},
              child: const Text('Connect saved peer'),
            ),
          ),
        ],
      ),
    ),
  );

  testWidgets(
    'unknown operation preserves cached connection and only looks up original ID',
    (tester) async {
      PendingAddressBookOperation? recovered;
      await tester.pumpWidget(
        panel(recover: (operation) async => recovered = operation),
      );
      expect(find.text(pending.operationId), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(
              find.widgetWithText(TextButton, 'Connect saved peer'),
            )
            .onPressed,
        isNotNull,
      );
      await tester.ensureVisible(find.text('Look up receipt'));
      await tester.tap(find.text('Look up receipt'));
      await tester.pump();
      expect(recovered, same(pending));
    },
  );

  testWidgets(
    'small viewport keeps connection access and scrolls recovery actions',
    (tester) async {
      tester.view.physicalSize = const Size(420, 260);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        panel(ready: false, error: 'Operation storage unavailable'),
      );
      expect(tester.takeException(), isNull);
      final connect = find.widgetWithText(TextButton, 'Connect saved peer');
      expect(tester.getRect(connect).height, greaterThan(0));
      await tester.tap(connect);
      await tester.ensureVisible(find.text('Manual reconciliation'));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('busy disables recovery and manual clearing, not connecting', (
    tester,
  ) async {
    await tester.pumpWidget(panel(busy: true));
    for (final label in ['Look up receipt', 'Manual reconciliation']) {
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, label))
            .onPressed,
        isNull,
      );
    }
    expect(
      tester
          .widget<TextButton>(
            find.widgetWithText(TextButton, 'Connect saved peer'),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets(
    'manual reconciliation requires exact ID plus explicit state verification',
    (tester) async {
      var reconciled = 0;
      await tester.pumpWidget(
        panel(
          reconcile: (operation, id) async {
            expect(operation, same(pending));
            expect(id, pending.operationId);
            reconciled++;
          },
        ),
      );
      await tester.ensureVisible(find.text('Manual reconciliation'));
      await tester.tap(find.text('Manual reconciliation'));
      await tester.pumpAndSettle();
      final button = find.byKey(const ValueKey('reconcile-confirm'));
      expect(tester.widget<TextButton>(button).onPressed, isNull);
      await tester.enterText(
        find.byKey(const ValueKey('reconcile-operation-id')),
        pending.operationId,
      );
      await tester.pump();
      expect(tester.widget<TextButton>(button).onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('reconcile-verified')));
      await tester.pump();
      expect(tester.widget<TextButton>(button).onPressed, isNotNull);
      await tester.enterText(
        find.byKey(const ValueKey('reconcile-operation-id')),
        'wrong-id',
      );
      await tester.pump();
      expect(tester.widget<TextButton>(button).onPressed, isNull);
      await tester.enterText(
        find.byKey(const ValueKey('reconcile-operation-id')),
        pending.operationId,
      );
      await tester.pump();
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(reconciled, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('cancel and storage failure never remove the unresolved record', (
    tester,
  ) async {
    var reconciled = 0;
    await tester.pumpWidget(
      panel(
        ready: false,
        error: 'Operation storage unavailable',
        reconcile: (_, _) async {
          reconciled++;
        },
      ),
    );
    expect(find.text('Operation storage unavailable'), findsOneWidget);
    await tester.ensureVisible(find.text('Manual reconciliation'));
    await tester.tap(find.text('Manual reconciliation'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(reconciled, 0);
    expect(find.text(pending.operationId), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
