import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/main_scanner.dart' as scanner_entry;
import 'package:frontend/screens/payment_qr_dialog.dart';
import 'package:frontend/screens/scanner_payment_app.dart';

void main() {
  PaymentQrData samplePoolQr({String status = 'PENDING', String? ref}) {
    return PaymentQrData.fromJson({
      'kind': 'POOL',
      'target_id': 'pool-123',
      'qr_data': 'KISANRIDER|pool-123|10000',
      'status': status,
      'total_amount': 10000.0,
      'rider_fare': 600.0,
      'platform_fee': 200.0,
      'farmers_net_payout': 9200.0,
      'rate_per_kg': 50.0,
      'rate_source': 'fallback',
      'crop_name': 'Tomato + Dragonfruit',
      'total_weight_kg': 200.0,
      'rider_name': 'Ramesh Rider',
      'mandi_name': 'Kolar APMC',
      'payment_reference': ref,
      'items': [
        {
          'settlement_id': 'stl-1',
          'farmer_name': 'Farmer A',
          'crop_name': 'Tomato',
          'weight_kg': 120.0,
          'rate_per_kg': 50.0,
          'rate_source': 'fallback',
          'gross_amount': 6000.0,
          'rider_fare': 360.0,
          'platform_fee': 120.0,
          'net_payout': 5520.0,
          'status': status,
        },
        {
          'settlement_id': 'stl-2',
          'farmer_name': 'Farmer B',
          'crop_name': 'Dragonfruit',
          'weight_kg': 80.0,
          'rate_per_kg': 50.0,
          'rate_source': 'fallback',
          'gross_amount': 4000.0,
          'rider_fare': 240.0,
          'platform_fee': 80.0,
          'net_payout': 3680.0,
          'status': status,
        },
      ],
    });
  }

  test('formatIndianRupees formats INR with Indian commas', () {
    expect(formatIndianRupees(50), '₹50');
    expect(formatIndianRupees(2000), '₹2,000');
    expect(formatIndianRupees(125000), '₹1,25,000');
  });

  testWidgets('Scanner entrypoint compiles and pumps cleanly', (tester) async {
    expect(scanner_entry.main, isA<Function>());
    await tester.pumpWidget(const KisanRiderScannerApp());
    await tester.pump();
    expect(find.byType(KisanRiderScannerApp), findsOneWidget);
    expect(find.text('Enter / Paste QR Code Manually'), findsOneWidget);
  });

  testWidgets('QrPaymentConfirmScreen enforces numeric PIN and shows split', (
    tester,
  ) async {
    final qr = samplePoolQr();
    await tester.pumpWidget(
      MaterialApp(
        home: QrPaymentConfirmScreen(
          baseUrl: 'http://127.0.0.1:8000',
          payment: qr,
        ),
      ),
    );

    expect(find.text('PAY ₹10,000 NOW'), findsOneWidget);
    expect(find.textContaining('Farmer A'), findsOneWidget);
    expect(find.textContaining('Farmer B'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'abcd');
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      isEmpty,
    );

    await tester.ensureVisible(find.text('PAY ₹10,000 NOW'));
    await tester.tap(find.text('PAY ₹10,000 NOW'));
    await tester.pump();

    expect(
      find.text('Enter a numeric PIN (4 to 8 digits only).'),
      findsOneWidget,
    );
  });

  testWidgets('PaymentSuccessReceiptScreen renders PAID receipt details', (
    tester,
  ) async {
    final paid = samplePoolQr(status: 'PAID', ref: 'KRP-TEST-001');
    await tester.pumpWidget(
      MaterialApp(home: PaymentSuccessReceiptScreen(receipt: paid)),
    );

    expect(find.text('Payment Successful!'), findsOneWidget);
    expect(find.text('Ref: KRP-TEST-001'), findsOneWidget);
    expect(find.text('₹10,000'), findsOneWidget);
  });
}
