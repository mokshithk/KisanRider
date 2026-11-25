import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:qr_flutter/qr_flutter.dart';

import 'rider_common.dart';

/// Formats rupees with Indian digit grouping (e.g. ₹12,345).
String formatIndianRupees(num? amount) {
  if (amount == null) return '—';
  final n = amount.round();
  final sign = n < 0 ? '-' : '';
  final s = n.abs().toString();
  if (s.length <= 3) return '$sign₹$s';

  final last3 = s.substring(s.length - 3);
  final rest = s.substring(0, s.length - 3);
  final groups = <String>[];
  var tail = rest;
  while (tail.length > 2) {
    groups.insert(0, tail.substring(tail.length - 2));
    tail = tail.substring(0, tail.length - 2);
  }
  if (tail.isNotEmpty) groups.insert(0, tail);
  return '$sign₹${groups.join(',')},$last3';
}

class PaymentSplitItem {
  PaymentSplitItem({
    required this.settlementId,
    required this.farmerName,
    required this.cropName,
    required this.weightKg,
    required this.ratePerKg,
    required this.rateSource,
    required this.grossAmount,
    required this.riderFare,
    required this.platformFee,
    required this.netPayout,
    required this.status,
  });

  factory PaymentSplitItem.fromJson(Map<String, dynamic> json) {
    return PaymentSplitItem(
      settlementId: (json['settlement_id'] ?? '').toString(),
      farmerName: (json['farmer_name'] ?? 'Farmer').toString(),
      cropName: (json['crop_name'] ?? 'Produce').toString(),
      weightKg: ((json['weight_kg'] ?? 0) as num).toDouble(),
      ratePerKg: ((json['rate_per_kg'] ?? 50) as num).toDouble(),
      rateSource: (json['rate_source'] ?? 'fallback').toString(),
      grossAmount: ((json['gross_amount'] ?? 0) as num).toDouble(),
      riderFare: ((json['rider_fare'] ?? 0) as num).toDouble(),
      platformFee: ((json['platform_fee'] ?? 0) as num).toDouble(),
      netPayout: ((json['net_payout'] ?? 0) as num).toDouble(),
      status: (json['status'] ?? 'PENDING').toString(),
    );
  }

  final String settlementId;
  final String farmerName;
  final String cropName;
  final double weightKg;
  final double ratePerKg;
  final String rateSource;
  final double grossAmount;
  final double riderFare;
  final double platformFee;
  final double netPayout;
  final String status;
}

class PaymentQrData {
  PaymentQrData({
    required this.kind,
    required this.targetId,
    required this.qrData,
    required this.status,
    required this.totalAmount,
    required this.riderFare,
    required this.platformFee,
    required this.farmersNetPayout,
    required this.ratePerKg,
    required this.rateSource,
    required this.cropName,
    required this.totalWeightKg,
    required this.riderName,
    required this.items,
    this.mandiName,
    this.paymentReference,
    this.paymentMethod,
    this.paidAt,
  });

  factory PaymentQrData.fromJson(Map<String, dynamic> json) {
    final rawItems = (json['items'] as List<dynamic>?) ?? const [];
    return PaymentQrData(
      kind: (json['kind'] ?? 'INDIVIDUAL').toString(),
      targetId: (json['target_id'] ?? '').toString(),
      qrData: (json['qr_data'] ?? '').toString(),
      status: (json['status'] ?? 'PENDING').toString(),
      totalAmount: ((json['total_amount'] ?? 0) as num).toDouble(),
      riderFare: ((json['rider_fare'] ?? 0) as num).toDouble(),
      platformFee: ((json['platform_fee'] ?? 0) as num).toDouble(),
      farmersNetPayout: ((json['farmers_net_payout'] ?? 0) as num).toDouble(),
      ratePerKg: ((json['rate_per_kg'] ?? 50) as num).toDouble(),
      rateSource: (json['rate_source'] ?? 'fallback').toString(),
      cropName: (json['crop_name'] ?? 'Produce').toString(),
      totalWeightKg: ((json['total_weight_kg'] ?? 0) as num).toDouble(),
      riderName: (json['rider_name'] ?? 'Rider').toString(),
      mandiName: json['mandi_name']?.toString(),
      paymentReference: json['payment_reference']?.toString(),
      paymentMethod: json['payment_method']?.toString(),
      paidAt: json['paid_at'] is String
          ? DateTime.tryParse(json['paid_at'] as String)
          : null,
      items: rawItems
          .whereType<Map<String, dynamic>>()
          .map(PaymentSplitItem.fromJson)
          .toList(growable: false),
    );
  }

  final String kind;
  final String targetId;
  final String qrData;
  final String status;
  final double totalAmount;
  final double riderFare;
  final double platformFee;
  final double farmersNetPayout;
  final double ratePerKg;
  final String rateSource;
  final String cropName;
  final double totalWeightKg;
  final String riderName;
  final String? mandiName;
  final String? paymentReference;
  final String? paymentMethod;
  final DateTime? paidAt;
  final List<PaymentSplitItem> items;

  bool get isPaid => status.toUpperCase() == 'PAID';
  bool get isPool => kind.toUpperCase() == 'POOL';
}

/// Opens the Payment QR dialog for an individual trip.
/// Returns `true` if payment completed as `PAID`.
Future<bool> showTripPaymentQrDialog(
  BuildContext context, {
  required String token,
  required String tripId,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PaymentQrDialog(
      token: token,
      generateUrl: '$kApiBaseUrl/trips/$tripId/generate-qr',
      statusUrl: '$kApiBaseUrl/trips/$tripId/payment-status',
      title: 'Mandi Payment QR',
    ),
  );
  return result == true;
}

/// Opens the Payment QR dialog for a whole pool (single QR for all farmers).
/// Returns `true` if payment completed as `PAID`.
Future<bool> showPoolPaymentQrDialog(
  BuildContext context, {
  required String token,
  required String poolId,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PaymentQrDialog(
      token: token,
      generateUrl: '$kApiBaseUrl/pools/$poolId/generate-qr',
      statusUrl: '$kApiBaseUrl/pools/$poolId/payment-status',
      title: 'Pool Payment QR',
    ),
  );
  return result == true;
}

/// Displays a real scannable QR code for the Mandi Owner and polls every
/// 3 seconds until payment completes, then closes QR and confirms payment.
class PaymentQrDialog extends StatefulWidget {
  const PaymentQrDialog({
    super.key,
    required this.token,
    required this.generateUrl,
    required this.statusUrl,
    this.title = 'Payment QR',
  });

  final String token;
  final String generateUrl;
  final String statusUrl;
  final String title;

  @override
  State<PaymentQrDialog> createState() => _PaymentQrDialogState();
}

class _PaymentQrDialogState extends State<PaymentQrDialog> {
  PaymentQrData? _data;
  bool _isLoading = true;
  String? _error;
  Timer? _pollTimer;
  bool _notifiedPaid = false;

  @override
  void initState() {
    super.initState();
    _generateQr();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Map<String, String> get _headers => {
        'Authorization': 'Bearer ${widget.token}',
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      };

  Future<void> _generateQr() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final resp = await http
          .post(Uri.parse(widget.generateUrl), headers: _headers)
          .timeout(const Duration(seconds: 15));

      if (!mounted) return;
      if (resp.statusCode == 200 || resp.statusCode == 201) {
        final parsed = PaymentQrData.fromJson(
          jsonDecode(resp.body) as Map<String, dynamic>,
        );
        setState(() {
          _data = parsed;
          _isLoading = false;
        });
        if (parsed.isPaid) {
          _onPaidDetected();
        } else {
          _startPolling();
        }
      } else {
        setState(() {
          _error = _extractErr(resp) ??
              'Could not generate QR (HTTP ${resp.statusCode}).';
          _isLoading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Network error: $e';
        _isLoading = false;
      });
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _pollStatus();
    });
  }

  Future<void> _pollStatus() async {
    if (!mounted) return;
    try {
      final resp = await http
          .get(Uri.parse(widget.statusUrl), headers: _headers)
          .timeout(const Duration(seconds: 10));
      if (!mounted || resp.statusCode != 200) return;

      final parsed = PaymentQrData.fromJson(
        jsonDecode(resp.body) as Map<String, dynamic>,
      );
      setState(() => _data = parsed);
      if (parsed.isPaid) {
        _onPaidDetected();
      }
    } catch (_) {
      // Transient polling errors are silently ignored; next tick retries.
    }
  }

  void _onPaidDetected() {
    _pollTimer?.cancel();
    _pollTimer = null;
    if (!_notifiedPaid) {
      _notifiedPaid = true;
      kPaymentEventsNotifier.value++;
    }
  }

  String? _extractErr(http.Response resp) {
    try {
      final decoded = jsonDecode(resp.body);
      if (decoded is Map && decoded['detail'] != null) {
        return decoded['detail'].toString();
      }
    } catch (_) {}
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final data = _data;
    final bool isPaid = data?.isPaid ?? false;

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: Row(
        children: [
          Icon(
            isPaid ? Icons.verified_rounded : Icons.qr_code_2_rounded,
            color: kRiderGreen,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              isPaid ? 'Payment Done!' : widget.title,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
          ),
          IconButton(
            onPressed: () => Navigator.of(context).pop(isPaid),
            icon: const Icon(Icons.close, size: 20),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
      content: SizedBox(
        width: 340,
        child: SingleChildScrollView(
          child: _isLoading
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: kRiderGreen),
                      SizedBox(height: 14),
                      Text(
                        'Fetching live mandi rate & generating QR…',
                        style: TextStyle(fontSize: 13, color: Colors.black54),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                )
              : _error != null
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.error_outline,
                            size: 44,
                            color: Colors.red.shade600,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.red.shade700,
                            ),
                          ),
                        ],
                      ),
                    )
                  : isPaid
                      ? _buildPaidReceipt(theme, data!)
                      : _buildQrWaitingView(theme, data!),
        ),
      ),
      actions: [
        if (_error != null)
          FilledButton.icon(
            onPressed: _generateQr,
            style: FilledButton.styleFrom(backgroundColor: kRiderGreen),
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Retry'),
          )
        else if (isPaid)
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => Navigator.of(context).pop(true),
              style: FilledButton.styleFrom(
                backgroundColor: kRiderGreen,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              icon: const Icon(Icons.check_circle_outline, size: 18),
              label: const Text('Done'),
            ),
          )
        else
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Close'),
          ),
      ],
    );
  }

  Widget _buildQrWaitingView(ThemeData theme, PaymentQrData d) {
    final rateLabel = d.rateSource == 'mandi_api'
        ? '₹${d.ratePerKg.toStringAsFixed(0)}/kg (Live Mandi Rate)'
        : '₹${d.ratePerKg.toStringAsFixed(0)}/kg (Standard Rate)';

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: kRiderGreen.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: kRiderGreen.withValues(alpha: 0.3)),
          ),
          child: Column(
            children: [
              Text(
                d.isPool
                    ? 'TOTAL POOL AMOUNT TO PAY'
                    : 'TOTAL CROP AMOUNT TO PAY',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: kRiderGreen,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                formatIndianRupees(d.totalAmount),
                style: const TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.bold,
                  color: kRiderGreen,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${d.cropName} · ${d.totalWeightKg.toStringAsFixed(0)} kg · $rateLabel',
                style: const TextStyle(fontSize: 12, color: Colors.black87),
                textAlign: TextAlign.center,
              ),
              if (d.mandiName != null && d.mandiName!.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  d.mandiName!,
                  style: const TextStyle(fontSize: 11.5, color: Colors.black54),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
        Center(
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.grey.shade300),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black12,
                  blurRadius: 6,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: QrImageView(
              data: d.qrData,
              version: QrVersions.auto,
              size: 205,
              backgroundColor: Colors.white,
            ),
          ),
        ),
        const SizedBox(height: 10),
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: d.qrData));
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('QR payload copied for demo testing.'),
                duration: Duration(seconds: 2),
              ),
            );
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: Text(
                    d.qrData,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10.5,
                      color: Colors.black54,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                const Icon(Icons.copy, size: 14, color: Colors.black45),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        _SplitSummaryCard(data: d),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: Colors.amber.shade50,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.amber.shade200),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.amber.shade900,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Ask Mandi Owner to scan using KisanRider Scanner. Auto-checking every 3s…',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: Colors.amber.shade900,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPaidReceipt(ThemeData theme, PaymentQrData d) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFFE8F5E9),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFA5D6A7), width: 1.5),
          ),
          child: Column(
            children: [
              const Icon(
                Icons.check_circle_rounded,
                color: Color(0xFF166534),
                size: 50,
              ),
              const SizedBox(height: 8),
              const Text(
                'Payment Received!',
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF166534),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                formatIndianRupees(d.totalAmount),
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF166534),
                ),
              ),
              if (d.paymentReference != null) ...[
                const SizedBox(height: 4),
                Text(
                  'Ref: ${d.paymentReference}',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF166534),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
        _SplitSummaryCard(data: d, paid: true),
      ],
    );
  }
}

class _SplitSummaryCard extends StatelessWidget {
  const _SplitSummaryCard({required this.data, this.paid = false});

  final PaymentQrData data;
  final bool paid;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            paid ? 'PAYMENT AUTO-SPLIT SUMMARY' : 'AUTO-SPLIT PREVIEW',
            style: const TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: Color(0xFF6B7280),
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 8),
          _SplitRow(
            label: 'Total Crop Sale',
            value: formatIndianRupees(data.totalAmount),
            bold: true,
          ),
          _SplitRow(
            label: 'Rider Fare (${data.riderName})',
            value: '- ${formatIndianRupees(data.riderFare)}',
            valueColor: kRiderGreen,
            bold: true,
          ),
          _SplitRow(
            label: 'Platform Fee (2%)',
            value: '- ${formatIndianRupees(data.platformFee)}',
            valueColor: Colors.red.shade700,
          ),
          const Divider(height: 14),
          _SplitRow(
            label: data.isPool
                ? 'Farmers Net (${data.items.length} Farmers)'
                : 'Farmer Net Payout',
            value: formatIndianRupees(data.farmersNetPayout),
            valueColor: const Color(0xFF166534),
            bold: true,
          ),
          if (data.isPool && data.items.length > 1) ...[
            const SizedBox(height: 8),
            ...data.items.map(
              (it) => Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '· ${it.farmerName} (${it.weightKg.toStringAsFixed(0)} kg)',
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: Colors.black54,
                        ),
                      ),
                    ),
                    Text(
                      formatIndianRupees(it.netPayout),
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: Colors.black87,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SplitRow extends StatelessWidget {
  const _SplitRow({
    required this.label,
    required this.value,
    this.valueColor,
    this.bold = false,
  });

  final String label;
  final String value;
  final Color? valueColor;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                color: Colors.black87,
                fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: bold ? FontWeight.bold : FontWeight.w600,
              color: valueColor ?? Colors.black87,
            ),
          ),
        ],
      ),
    );
  }
}
