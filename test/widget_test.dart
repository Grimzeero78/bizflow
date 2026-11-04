import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:stockipa/main.dart';
import 'package:stockipa/models.dart';

void main() {
  test('AppProvider starts with empty transaction and stock lists', () {
    final provider = AppProvider();

    expect(provider.transactions, isEmpty);
    expect(provider.stockItems, isEmpty);
  });

  testWidgets('Home layout remains stable at accessibility text sizes',
      (tester) async {
    final provider = AppProvider();
    provider.settings.language = 'sw';
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final scale in [1.0, 1.3, 2.0]) {
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: provider,
          child: MaterialApp(
            home: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: const Scaffold(body: HomePage()),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.takeException(),
        isNull,
        reason: 'Home should not overflow at ${scale * 100}% text size.',
      );
    }
  });

  testWidgets('Home manual entries remain readable at large text sizes',
      (tester) async {
    final provider = AppProvider();
    provider.transactions.add(
      Transaction(
        id: 'large-text-entry',
        type: 'sale',
        amount: 1250,
        description: 'Manual sale entry',
        date: DateTime.now(),
      ),
    );
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: const Scaffold(body: HomePage()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Manual sale entry'),
      300,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.text('Manual sale entry'), findsOneWidget);
    expect(find.byType(Table), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Inventory cards remain usable on a small screen at large text',
      (tester) async {
    final provider = AppProvider();
    provider.settings.language = 'sw';
    provider.stockItems.add(
      StockItem(
        id: 'item-1',
        name: 'Mafuta ya kupikia ya biashara kwa matumizi ya kila siku',
        quantity: 8,
        initialQuantity: 12,
        buyingPrice: 100,
        sellingPrice: 150,
        dateAdded: DateTime(2026),
      ),
    );
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final scale in [1.0, 1.3, 2.0]) {
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: provider,
          child: MaterialApp(
            home: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: const Scaffold(body: StockPage()),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.takeException(),
        isNull,
        reason: 'Inventory should not overflow at ${scale * 100}% text size.',
      );
    }
  });

  testWidgets('Entry forms remain scrollable at accessibility text sizes',
      (tester) async {
    final provider = AppProvider();
    provider.settings.language = 'sw';
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final scale in [1.0, 1.3, 2.0]) {
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: provider,
          child: MaterialApp(
            home: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: const Scaffold(body: StockForm()),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.takeException(),
        isNull,
        reason: 'Stock form should not overflow at ${scale * 100}% text size.',
      );

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: provider,
          child: MaterialApp(
            home: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: const Scaffold(body: DailyGoalsForm()),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.takeException(),
        isNull,
        reason: 'Goals form should not overflow at ${scale * 100}% text size.',
      );
    }
  });

  testWidgets('Tracking and settings layouts adapt to large text',
      (tester) async {
    final provider = AppProvider();
    provider.settings.language = 'sw';
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final scale in [1.0, 1.3, 2.0]) {
      for (final page in [const TrackingPage(), const SettingsPage()]) {
        await tester.pumpWidget(
          ChangeNotifierProvider.value(
            value: provider,
            child: MaterialApp(
              home: Builder(
                builder: (context) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(scale)),
                  child: Scaffold(body: page),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.takeException(),
          isNull,
          reason:
              '${page.runtimeType} should not overflow at ${scale * 100}% text size.',
        );
      }
    }
  });

  testWidgets('Contact support layout wraps at large text sizes',
      (tester) async {
    final provider = AppProvider();
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: const Scaffold(body: SettingsPage()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Email: support@injuguna308@gmail.com'),
      300,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.text('Email: support@injuguna308@gmail.com'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Settings exposes an explicit notification opt-in',
      (tester) async {
    final provider = AppProvider();
    provider.settings.language = 'en';

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: const MaterialApp(
          home: Scaffold(body: SettingsPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Notifications'), findsOneWidget);
    expect(
      find.text(provider.translations['enableNotifications']!),
      findsNWidgets(2),
    );
    expect(find.byType(SwitchListTile), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Home and Tracking use the same daily money summary',
      (tester) async {
    final provider = AppProvider();
    provider.settings.currency = 'USD';
    final today = DateTime.now();
    provider.transactions.addAll([
      Transaction(
        id: 'sale',
        type: 'sale',
        amount: 125.5,
        description: 'Sale',
        date: today,
      ),
      Transaction(
        id: 'expense',
        type: 'expense',
        amount: 24.25,
        description: 'Expense',
        date: today,
      ),
      Transaction(
        id: 'savings',
        type: 'savings',
        amount: 10,
        description: 'Savings',
        date: today,
      ),
    ]);

    Future<DailyMoneySummary> pumpPage(Widget page) async {
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: provider,
          child: MaterialApp(
            home: Scaffold(body: page),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(DailyMoneySummary), findsOneWidget);
      return tester.widget<DailyMoneySummary>(find.byType(DailyMoneySummary));
    }

    final homeSummary = await pumpPage(const HomePage());
    final trackingSummary = await pumpPage(const TrackingPage());

    expect(homeSummary.income, trackingSummary.income);
    expect(homeSummary.expenses, trackingSummary.expenses);
    expect(homeSummary.savings, trackingSummary.savings);
    expect(homeSummary.margin, trackingSummary.margin);
    expect(homeSummary.income, 125.5);
    expect(homeSummary.expenses, 24.25);
    expect(homeSummary.savings, 10);
  });

  testWidgets('Tracking All view shows older manual entries', (tester) async {
    final provider = AppProvider();
    final olderDate = DateTime.now().subtract(const Duration(days: 40));
    provider.transactions.addAll([
      Transaction(
        id: 'manual-old',
        type: 'sale',
        amount: 125,
        description: 'Older manual sale',
        date: olderDate,
      ),
    ]);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: const MaterialApp(
          home: Scaffold(body: TrackingPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Older manual sale'), findsOneWidget);
    expect(
      find.text(
          provider.translations['manualEntrySection'] ?? 'Manual Entries'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Navigation labels remain visible at large text sizes',
      (tester) async {
    final provider = AppProvider();
    provider.settings.language = 'sw';
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final scale in [1.0, 1.3, 2.0]) {
      final t = provider.translations;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                bottomNavigationBar: BottomNavigationBar(
                  currentIndex: 0,
                  type: BottomNavigationBarType.fixed,
                  selectedFontSize: 12,
                  unselectedFontSize: 12,
                  items: [
                    BottomNavigationBarItem(
                        icon: const Icon(Icons.home), label: t['home']),
                    BottomNavigationBarItem(
                        icon: const Icon(Icons.trending_up),
                        label: t['tracking']),
                    BottomNavigationBarItem(
                        icon: const Icon(Icons.inventory), label: t['stock']),
                    BottomNavigationBarItem(
                        icon: const Icon(Icons.settings), label: t['settings']),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.takeException(),
        isNull,
        reason: 'Navigation should not overflow at ${scale * 100}% text size.',
      );
    }
  });
}
