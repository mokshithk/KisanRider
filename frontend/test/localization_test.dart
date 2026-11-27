import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:frontend/l10n/app_strings.dart';
import 'package:frontend/providers/language_provider.dart';

void main() {
  const MethodChannel secureStorageChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  final Map<String, String> memoryStorage = <String, String>{};

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (MethodCall call) async {
      final args = (call.arguments as Map?) ?? const <dynamic, dynamic>{};
      final key = args['key']?.toString();
      switch (call.method) {
        case 'read':
          return key == null ? null : memoryStorage[key];
        case 'write':
          if (key != null && args['value'] != null) {
            memoryStorage[key] = args['value'].toString();
          }
          return null;
        case 'delete':
          if (key != null) memoryStorage.remove(key);
          return null;
        case 'deleteAll':
          memoryStorage.clear();
          return null;
        default:
          return null;
      }
    });
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
  });

  setUp(() async {
    memoryStorage.clear();
    await LanguageProvider.instance.setLanguage('en');
  });

  group('AppStrings localization', () {
    test('English mode returns original strings and arguments unchanged', () {
      expect(AppStrings.currentLanguage, 'en');
      expect(AppStrings.tr('Log In'), 'Log In');
      expect(
        AppStrings.tr(
          'Capacity: {cur} / {max} kg',
          args: {'cur': '50', 'max': '100'},
        ),
        'Capacity: 50 / 100 kg',
      );
      expect(AppStrings.trStatus('PENDING'), 'PENDING');
      expect(AppStrings.trStatus('SETTLED'), 'SETTLED');
      expect(AppStrings.trStatus('FULL'), 'FULL');
      expect(AppStrings.trShortMonth(5), 'May');
      expect(AppStrings.trFullMonth(5), 'May');
      expect(AppStrings.trRole('farmer'), 'farmer');
      expect(AppStrings.tr('Unknown Untranslated Key'), 'Unknown Untranslated Key');
    });

    test('Kannada mode translates UI labels, arguments, statuses, and districts', () async {
      await LanguageProvider.instance.setLanguage('kn');

      expect(AppStrings.currentLanguage, 'kn');
      expect(AppStrings.tr('Log In'), isNot('Log In'));
      expect(AppStrings.tr('Vijayapura'), 'ವಿಜಯಪುರ');
      expect(AppStrings.tr('estimated'), 'ಅಂದಾಜು');
      expect(
        AppStrings.tr('{weight} kg', args: {'weight': '250'}),
        contains('250'),
      );
      expect(AppStrings.trStatus('SETTLED'), 'ಪಾವತಿ ಇತ್ಯರ್ಥವಾಗಿದೆ');
      expect(AppStrings.trStatus('FULL'), 'ಭರ್ತಿಯಾಗಿದೆ');
      expect(AppStrings.trStatus('PENDING'), isNot('PENDING'));
      expect(AppStrings.trShortMonth(1), isNot('Jan'));
      expect(AppStrings.trFullMonth(1), isNot('January'));
      expect(AppStrings.trRole('farmer'), isNot('farmer'));
      expect(AppStrings.trRole('rider'), isNot('rider'));
      expect(AppStrings.tr('Unknown Key Falls Back'), 'Unknown Key Falls Back');
    });

    test('Invalid language codes normalize safely to English and persist via load()', () async {
      await LanguageProvider.instance.setLanguage('kn');
      expect(LanguageProvider.instance.isKannada, isTrue);

      await LanguageProvider.instance.setLanguage('fr');
      expect(LanguageProvider.instance.languageCode, 'en');
      expect(LanguageProvider.instance.isKannada, isFalse);
      expect(AppStrings.currentLanguage, 'en');

      memoryStorage['kisanrider_language_code'] = 'kn';
      await LanguageProvider.instance.load();
      expect(LanguageProvider.instance.languageCode, 'kn');
      expect(AppStrings.currentLanguage, 'kn');
    });
  });

  testWidgets('UI rebuilds reactively when LanguageProvider switches language', (
    tester,
  ) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<LanguageProvider>.value(
        value: LanguageProvider.instance,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Column(
                children: [
                  Text(context.tr('Log In')),
                  Text(context.tr('Vijayapura')),
                  Text(context.trStatus('SETTLED')),
                  Text(context.trStatus('FULL')),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Log In'), findsOneWidget);
    expect(find.text('Vijayapura'), findsOneWidget);
    expect(find.text('SETTLED'), findsOneWidget);
    expect(find.text('FULL'), findsOneWidget);

    await tester.runAsync(() => LanguageProvider.instance.setLanguage('kn'));
    await tester.pump();

    expect(find.text('Log In'), findsNothing);
    expect(find.text('ವಿಜಯಪುರ'), findsOneWidget);
    expect(find.text('ಪಾವತಿ ಇತ್ಯರ್ಥವಾಗಿದೆ'), findsOneWidget);
    expect(find.text('ಭರ್ತಿಯಾಗಿದೆ'), findsOneWidget);

    await tester.runAsync(() => LanguageProvider.instance.setLanguage('en'));
    await tester.pump();

    expect(find.text('Log In'), findsOneWidget);
    expect(find.text('Vijayapura'), findsOneWidget);
    expect(find.text('SETTLED'), findsOneWidget);
    expect(find.text('FULL'), findsOneWidget);
  });
}
