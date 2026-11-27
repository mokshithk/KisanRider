import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';

import 'payment_qr_dialog.dart';
import 'rider_common.dart';

/// App #2 — KisanRider Demo Mandi Payment Scanner App.
/// Run via: `flutter run -t lib/main_scanner.dart`
class KisanRiderScannerApp extends StatelessWidget {
  const KisanRiderScannerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'KisanRider Mandi Pay',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: kRiderGreen,
          primary: kRiderGreen,
        ),
        fontFamily: 'AppRoboto',
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF8FAF9),
      ),
      home: const ScannerHomeScreen(),
    );
  }
}

class ScannerHomeScreen extends StatefulWidget {
  const ScannerHomeScreen({super.key});

  @override
  State<ScannerHomeScreen> createState() => _ScannerHomeScreenState();
}

class _ScannerHomeScreenState extends State<ScannerHomeScreen> {
  final MobileScannerController _scannerController = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.normal,
  );

  String _baseUrl = kApiBaseUrl;
  bool _isInspecting = false;
  String? _scanError;

  @override
  void dispose() {
    _scannerController.dispose();
    super.dispose();
  }

  Future<void> _handleQrString(String rawQr) async {
    final trimmed = rawQr.trim();
    if (trimmed.isEmpty || _isInspecting) return;

    setState(() {
      _isInspecting = true;
      _scanError = null;
    });

    try {
      await _scannerController.stop();
    } catch (_) {}

    try {
      final uri = Uri.parse('$_baseUrl/payments/qr/inspect').replace(
        queryParameters: {'qr_data': trimmed},
      );
      final resp = await http
          .get(uri, headers: const {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 45));

      if (!mounted) return;

      if (resp.statusCode == 200) {
        final data = PaymentQrData.fromJson(
          jsonDecode(resp.body) as Map<String, dynamic>,
        );
        setState(() => _isInspecting = false);

        if (data.isPaid) {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => PaymentSuccessReceiptScreen(
                receipt: data,
                alreadyPaid: true,
              ),
            ),
          );
        } else {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => QrPaymentConfirmScreen(
                baseUrl: _baseUrl,
                payment: data,
              ),
            ),
          );
        }
        if (!mounted) return;
        try {
          await _scannerController.start();
        } catch (_) {}
      } else {
        String msg = 'Invalid KisanRider QR (HTTP ${resp.statusCode}).';
        try {
          final b = jsonDecode(resp.body);
          if (b is Map && b['detail'] != null) msg = b['detail'].toString();
        } catch (_) {}
        setState(() {
          _isInspecting = false;
          _scanError = msg;
        });
        try {
          await _scannerController.start();
        } catch (_) {}
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isInspecting = false;
        _scanError = 'Could not reach backend ($_baseUrl): $e';
      });
      try {
        await _scannerController.start();
      } catch (_) {}
    }
  }

  Future<void> _showManualEntryDialog() async {
    final controller = TextEditingController();
    final qr = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Enter Payment QR Code'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'QR Payload',
            hintText: 'KISANRIDER|<id>|<amount>',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: kRiderGreen),
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Inspect'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (qr != null && qr.isNotEmpty) {
      await _handleQrString(qr);
    }
  }

  Future<void> _showServerConfigDialog() async {
    final controller = TextEditingController(text: _baseUrl);
    final updated = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Backend Server URL'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'https://kisanrider.onrender.com',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: kRiderGreen),
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (updated != null && updated.isNotEmpty && mounted) {
      setState(() => _baseUrl = updated.replaceAll(RegExp(r'/+$'), ''));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('KisanRider Mandi Pay'),
        backgroundColor: kRiderGreen,
        foregroundColor: Colors.white,
        actions: [
          ValueListenableBuilder<MobileScannerState>(
            valueListenable: _scannerController,
            builder: (_, state, _) {
              final torchOn = state.torchState == TorchState.on;
              return IconButton(
                tooltip: 'Toggle Flash',
                onPressed: state.isRunning ? () => _scannerController.toggleTorch() : null,
                icon: Icon(torchOn ? Icons.flash_on : Icons.flash_off),
              );
            },
          ),
          IconButton(
            tooltip: 'Flip Camera',
            onPressed: () => _scannerController.switchCamera(),
            icon: const Icon(Icons.cameraswitch_outlined),
          ),
          IconButton(
            tooltip: 'Server Settings',
            onPressed: _showServerConfigDialog,
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                Container(
                  color: const Color(0xFF0F172A),
                  child: MobileScanner(
                    controller: _scannerController,
                    onDetect: (capture) {
                      if (_isInspecting) return;
                      for (final barcode in capture.barcodes) {
                        final raw = barcode.rawValue;
                        if (raw != null && raw.trim().isNotEmpty) {
                          _handleQrString(raw);
                          break;
                        }
                      }
                    },
                    errorBuilder: (_, error) => Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.videocam_off_outlined,
                              size: 54,
                              color: Colors.white70,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'Camera unavailable (${error.errorCode.name}).\nUse "Enter QR Code" below for demo testing.',
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white70, fontSize: 13.5),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                // Scan reticle frame
                Center(
                  child: Container(
                    width: 240,
                    height: 240,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: const Color(0xFF4ADE80),
                        width: 3,
                      ),
                    ),
                  ),
                ),
                if (_isInspecting)
                  Container(
                    color: Colors.black54,
                    child: const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(color: Colors.white),
                          SizedBox(height: 12),
                          Text(
                            'Reading KisanRider Payment QR…',
                            style: TextStyle(color: Colors.white, fontSize: 14),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 22),
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(top: BorderSide(color: Color(0xFFE5E7EB))),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.qr_code_scanner, color: kRiderGreen, size: 22),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Scan Rider\'s KisanRider QR Code to Pay',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF1C1B1F),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Amount and auto-split (Rider Fare, Platform Fee & Farmer Payout) load automatically.',
                    style: TextStyle(fontSize: 12.5, color: Color(0xFF6B7280)),
                  ),
                  if (_scanError != null) ...[
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.red.shade200),
                      ),
                      child: Text(
                        _scanError!,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: Colors.red.shade800,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  OutlinedButton.icon(
                    onPressed: _isInspecting ? null : _showManualEntryDialog,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: kRiderGreen,
                      side: const BorderSide(color: kRiderGreen),
                      padding: const EdgeInsets.symmetric(vertical: 13),
                    ),
                    icon: const Icon(Icons.keyboard_alt_outlined, size: 19),
                    label: const Text('Enter / Paste QR Code Manually'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class QrPaymentConfirmScreen extends StatefulWidget {
  const QrPaymentConfirmScreen({
    super.key,
    required this.baseUrl,
    required this.payment,
  });

  final String baseUrl;
  final PaymentQrData payment;

  @override
  State<QrPaymentConfirmScreen> createState() => _QrPaymentConfirmScreenState();
}

class _QrPaymentConfirmScreenState extends State<QrPaymentConfirmScreen> {
  final TextEditingController _pinController = TextEditingController();
  bool _isPaying = false;
  String? _error;

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _submitPay() async {
    final pin = _pinController.text.trim();
    if (pin.isEmpty || !RegExp(r'^\d{4,8}$').hasMatch(pin)) {
      setState(() => _error = 'Enter a numeric PIN (4 to 8 digits only).');
      return;
    }

    setState(() {
      _isPaying = true;
      _error = null;
    });

    try {
      final resp = await http
          .post(
            Uri.parse('${widget.baseUrl}/payments/qr/pay'),
            headers: const {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({
              'qr_data': widget.payment.qrData,
              'pin': pin,
            }),
          )
          .timeout(const Duration(seconds: 45));

      if (!mounted) return;

      if (resp.statusCode == 200) {
        final receipt = PaymentQrData.fromJson(
          jsonDecode(resp.body) as Map<String, dynamic>,
        );
        await Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) => PaymentSuccessReceiptScreen(receipt: receipt),
          ),
        );
      } else {
        String msg = 'Payment failed (HTTP ${resp.statusCode}).';
        try {
          final b = jsonDecode(resp.body);
          if (b is Map && b['detail'] != null) msg = b['detail'].toString();
        } catch (_) {}
        setState(() {
          _isPaying = false;
          _error = msg;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isPaying = false;
        _error = 'Network error: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.payment;
    final rateNote = p.rateSource == 'mandi_api'
        ? '₹${p.ratePerKg.toStringAsFixed(0)}/kg · Live Mandi API'
        : '₹${p.ratePerKg.toStringAsFixed(0)}/kg · Standard Rate';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Confirm Mandi Payment'),
        backgroundColor: kRiderGreen,
        foregroundColor: Colors.white,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Amount Banner
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      kRiderGreen.withValues(alpha: 0.14),
                      kRiderGreen.withValues(alpha: 0.04),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: kRiderGreen.withValues(alpha: 0.35)),
                ),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: kRiderGreen,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        p.isPool
                            ? 'POOLED DELIVERY · ${p.items.length} FARMERS'
                            : 'INDIVIDUAL DELIVERY',
                        style: const TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                          letterSpacing: 0.7,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'PAYABLE AMOUNT',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF4B5563),
                        letterSpacing: 0.9,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      formatIndianRupees(p.totalAmount),
                      style: const TextStyle(
                        fontSize: 38,
                        fontWeight: FontWeight.bold,
                        color: kRiderGreen,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${p.cropName} · ${p.totalWeightKg.toStringAsFixed(0)} kg · $rateNote',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1F2937),
                      ),
                      textAlign: TextAlign.center,
                    ),
                    if (p.mandiName != null && p.mandiName!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Mandi: ${p.mandiName}',
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: Color(0xFF6B7280),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Split Details Card
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'AUTOMATIC PAYMENT SPLIT',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF6B7280),
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _ScannerRow(
                      label: 'Rider Account (${p.riderName})',
                      value: formatIndianRupees(p.riderFare),
                      color: kRiderGreen,
                      bold: true,
                    ),
                    _ScannerRow(
                      label: 'Platform Fee (2%)',
                      value: formatIndianRupees(p.platformFee),
                      color: Colors.blueGrey.shade700,
                    ),
                    const Divider(height: 16),
                    _ScannerRow(
                      label: p.isPool
                          ? 'Farmers Net Total'
                          : 'Farmer Account (${p.items.isNotEmpty ? p.items.first.farmerName : "Farmer"})',
                      value: formatIndianRupees(p.farmersNetPayout),
                      color: const Color(0xFF166534),
                      bold: true,
                    ),
                    if (p.isPool && p.items.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      ...p.items.map(
                        (it) => Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '• ${it.farmerName} (${it.weightKg.toStringAsFixed(0)} kg)',
                                  style: const TextStyle(
                                    fontSize: 12.5,
                                    color: Color(0xFF4B5563),
                                  ),
                                ),
                              ),
                              Text(
                                formatIndianRupees(it.netPayout),
                                style: const TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // PIN Card
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Enter Demo Payment PIN',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Any 4 to 8 numeric digits accepted for demo authorization.',
                      style: TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _pinController,
                      enabled: !_isPaying,
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(8),
                      ],
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 26,
                        letterSpacing: 10,
                        fontWeight: FontWeight.bold,
                      ),
                      decoration: InputDecoration(
                        hintText: '••••',
                        errorText: _error,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        prefixIcon: const Icon(Icons.lock_outline, color: kRiderGreen),
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _isPaying ? null : _submitPay,
                      style: FilledButton.styleFrom(
                        backgroundColor: kRiderGreen,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        textStyle: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      icon: _isPaying
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.payments_outlined),
                      label: Text(
                        _isPaying
                            ? 'Processing Payment…'
                            : 'PAY ${formatIndianRupees(p.totalAmount)} NOW',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class PaymentSuccessReceiptScreen extends StatelessWidget {
  const PaymentSuccessReceiptScreen({
    super.key,
    required this.receipt,
    this.alreadyPaid = false,
  });

  final PaymentQrData receipt;
  final bool alreadyPaid;

  @override
  Widget build(BuildContext context) {
    final r = receipt;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Payment Receipt'),
        backgroundColor: kRiderGreen,
        foregroundColor: Colors.white,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: const Color(0xFFE8F5E9),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFFA5D6A7), width: 1.5),
                ),
                child: Column(
                  children: [
                    const Icon(
                      Icons.check_circle_rounded,
                      size: 64,
                      color: Color(0xFF166534),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      alreadyPaid
                          ? 'Already Paid'
                          : 'Payment Successful!',
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF166534),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      formatIndianRupees(r.totalAmount),
                      style: const TextStyle(
                        fontSize: 34,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF166534),
                      ),
                    ),
                    if (r.paymentReference != null) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          'Ref: ${r.paymentReference}',
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF166534),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'SETTLED SPLIT BREAKDOWN',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF6B7280),
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _ScannerRow(
                      label: 'Rider Credited (${r.riderName})',
                      value: formatIndianRupees(r.riderFare),
                      color: kRiderGreen,
                      bold: true,
                    ),
                    _ScannerRow(
                      label: 'Platform Fee (2%)',
                      value: formatIndianRupees(r.platformFee),
                    ),
                    const Divider(height: 16),
                    _ScannerRow(
                      label: 'Farmer Net Credited',
                      value: formatIndianRupees(r.farmersNetPayout),
                      color: const Color(0xFF166534),
                      bold: true,
                    ),
                    if (r.isPool && r.items.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      ...r.items.map(
                        (it) => Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '• ${it.farmerName} (${it.weightKg.toStringAsFixed(0)} kg)',
                                  style: const TextStyle(
                                    fontSize: 12.5,
                                    color: Color(0xFF4B5563),
                                  ),
                                ),
                              ),
                              Text(
                                formatIndianRupees(it.netPayout),
                                style: const TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF166534),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: () => Navigator.of(context).pop(),
                style: FilledButton.styleFrom(
                  backgroundColor: kRiderGreen,
                  padding: const EdgeInsets.symmetric(vertical: 15),
                ),
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text(
                  'Scan Next QR',
                  style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScannerRow extends StatelessWidget {
  const _ScannerRow({
    required this.label,
    required this.value,
    this.color,
    this.bold = false,
  });

  final String label;
  final String value;
  final Color? color;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 14,
              fontWeight: bold ? FontWeight.bold : FontWeight.w600,
              color: color ?? const Color(0xFF111827),
            ),
          ),
        ],
      ),
    );
  }
}
