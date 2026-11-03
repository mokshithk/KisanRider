import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/main.dart';

void main() {
  testWidgets('KisanRiderApp smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const KisanRiderApp());
    expect(find.byType(KisanRiderApp), findsOneWidget);
  });
}
