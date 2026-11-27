import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:frontend/l10n/app_strings.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/providers/language_provider.dart';
import 'package:frontend/screens/farmer_orders_tab.dart';
import 'package:frontend/widgets/segmented_filter_bar.dart';

void main() {
  const MethodChannel secureStorageChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (_) async => null);
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
  });

  setUp(() async {
    await LanguageProvider.instance.setLanguage('en');
  });

  FarmerOrder buildOrder(String status) => FarmerOrder(
        id: '11111111-1111-1111-1111-111111111111',
        cropType: 'Tomatoes',
        weightKg: 100,
        status: status,
        createdAt: DateTime(2026, 11, 27),
      );

  group('FarmerOrder All filter visibility', () {
    test('isOngoing includes active/in-transit statuses and excludes completed/cancelled', () {
      for (final s in ['PENDING', 'ACCEPTED', 'PICKED_UP', 'IN_TRANSIT']) {
        expect(buildOrder(s).isOngoing, isTrue, reason: '$s should appear in All');
      }

      for (final s in ['COMPLETED', 'DELIVERED', 'CANCELLED', 'EXPIRED', 'MISSED']) {
        expect(
          buildOrder(s).isOngoing,
          isFalse,
          reason: '$s must be excluded from All',
        );
      }
    });
  });

  group('SegmentedFilterBar layout & interaction', () {
    testWidgets('Rider Active Trips 4 segments fit 360dp width cleanly in EN and KN', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      int selected = 0;
      const labels = ['All', 'Accepted', 'Picked Up', 'Pooled'];

      await tester.pumpWidget(
        ChangeNotifierProvider<LanguageProvider>.value(
          value: LanguageProvider.instance,
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) => SegmentedFilterBar<int>(
                  options: [
                    for (int i = 0; i < labels.length; i++)
                      SegmentedFilterOption(
                        value: i,
                        label: context.tr(labels[i]),
                      ),
                  ],
                  selectedValue: selected,
                  onChanged: (v) => setState(() => selected = v),
                  accentColor: const Color(0xFF2E7D32),
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.byType(SegmentedButton<int>), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNothing);
      for (final label in labels) {
        expect(find.text(label), findsOneWidget);
      }

      await tester.tap(find.text('Pooled'));
      await tester.pump();
      expect(selected, 3);

      await tester.runAsync(() => LanguageProvider.instance.setLanguage('kn'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('FarmerOrdersTab segments', () {
    testWidgets('uses SegmentedButton with All, Active, In Transit, Pooled and no Completed', (
      tester,
    ) async {
      final ordersKey = GlobalKey<FarmerOrdersTabState>();

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<LanguageProvider>.value(
              value: LanguageProvider.instance,
            ),
            ChangeNotifierProvider<AuthProvider>(
              create: (_) => AuthProvider(),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: FarmerOrdersTab(
                key: ordersKey,
                onBookTransport: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SegmentedButton<int>), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNothing);

      expect(find.text('All'), findsOneWidget);
      expect(find.text('Active'), findsOneWidget);
      expect(find.text('In Transit'), findsOneWidget);
      expect(find.text('Pooled'), findsOneWidget);
      expect(find.text('Completed'), findsNothing);

      // Selecting removed tag is a safe no-op.
      ordersKey.currentState!.selectFilterTag('completed');
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
