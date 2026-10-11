import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;   // <-- ADDED
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';

/// Base URL of the FastAPI backend.
String get _kApiBaseUrl {
  if (kIsWeb) return 'http://localhost:8000';
  return 'http://10.28.1.142:8000';
}

/// Brand green matching the rest of the farmer UI.
const Color _kFarmerGreen = Color(0xFF2E7D32);

/// Farmer-side earnings / payout history view.
///
/// Reads `GET /settlements/me`, which the backend now serves role-aware:
/// for a FARMER it returns settlements where `farmer_id == current_user.id`,
/// carrying the farmer payout breakdown (gross sale, rider fare,
/// platform fee, net credited).
///
/// Older settlement rows may have nulls in the farmer-specific fields (they
/// were created before those columns existed). Those tiles show what data
/// is available and fall back gracefully rather than breaking the layout.
class FarmerEarningsTab extends StatefulWidget {
  const FarmerEarningsTab({super.key});

  @override
  State<FarmerEarningsTab> createState() => _FarmerEarningsTabState();
}

class _FarmerEarningsTabState extends State<FarmerEarningsTab>
    with AutomaticKeepAliveClientMixin {
  /// Raw settlement rows from the backend. Kept as maps rather than a
  /// typed model because the schema is still evolving (new farmer fields
  /// were added recently), and the derived values — total net sales,
  /// per-tile formatting — are easy to compute from maps directly.
  List<Map<String, dynamic>> _settlements = [];

  bool _isLoading = true;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _fetch());
  }

  // -------------------------------------------------------------------------
  // Networking
  // -------------------------------------------------------------------------

  Map<String, String> _headers(AuthProvider auth) {
    return {
      'Authorization': 'Bearer ${auth.token}',
      'Accept': 'application/json',
    };
  }

  Future<void> _fetch() async {
    final auth = context.read<AuthProvider>();
    if (auth.token == null) {
      setState(() {
        _isLoading = false;
        _error = 'Not signed in.';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final response = await http.get(
        Uri.parse('$_kApiBaseUrl/settlements/me'),
        headers: _headers(auth),
      );
      if (!mounted) return;

      if (response.statusCode == 200) {
        final List<dynamic> decoded = jsonDecode(response.body) as List<dynamic>;
        setState(() {
          _settlements = decoded
              .whereType<Map<String, dynamic>>()
              .toList(growable: false);
          _isLoading = false;
        });
      } else {
        setState(() {
          _error = _extractError(response) ??
              'Failed to load settlements (HTTP ${response.statusCode}).';
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

  String? _extractError(http.Response response) {
    try {
      final body = jsonDecode(response.body);
      if (body is Map && body['detail'] != null) {
        return body['detail'].toString();
      }
    } catch (_) {}
    return null;
  }

  // -------------------------------------------------------------------------
  // Derived values & formatting
  // -------------------------------------------------------------------------

  /// Sum of `net_payout` across all settlements that have one. Rows where
  /// `net_payout` is null (pre-farmer-columns or still being computed)
  /// don't contribute, and don't break the sum either.
  double get _totalNetSales {
    double sum = 0;
    for (final s in _settlements) {
      final v = s['net_payout'];
      if (v is num) sum += v.toDouble();
    }
    return sum;
  }

  /// Extracts a numeric value from a JSON field, tolerating int, double, or
  /// numeric strings. Returns null for anything else (including missing).
  double? _num(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  /// Formats a rupee amount with Indian digit grouping (12,34,567) rather
  /// than western (1,234,567). Whole rupees only.
  String _rupees(num? amount) {
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

  /// DD/MM/YYYY for a settlement's `created_at`. Falls back to '—' on a
  /// missing or unparseable value.
  String _shortDate(dynamic raw) {
    if (raw is! String) return '—';
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return '—';
    final local = parsed.toLocal();
    return '${local.day.toString().padLeft(2, '0')}/'
        '${local.month.toString().padLeft(2, '0')}/'
        '${local.year}';
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return _ErrorView(message: _error!, onRetry: _fetch);
    }

    return RefreshIndicator(
      onRefresh: _fetch,
      color: _kFarmerGreen,
      child: ListView(
        // Always scrollable so pull-to-refresh works even in the empty state.
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          _FinancialSummaryCard(totalNetSales: _totalNetSales),
          const SizedBox(height: 24),
          _SectionTitle(
            title: 'Sales Settlement History',
            count: _settlements.length,
          ),
          const SizedBox(height: 12),
          if (_settlements.isEmpty)
            const _EmptyEarningsState()
          else
            ..._settlements.map(_buildSettlementCard),
        ],
      ),
    );
  }

  Widget _buildSettlementCard(Map<String, dynamic> s) {
    // Farmer-side breakdown. Every field here can be null on older rows.
    final cropName = (s['crop_name'] ?? '').toString();
    final quantityKg = _num(s['quantity_kg']);
    final grossAmount = _num(s['gross_amount']);
    final riderFare = _num(s['rider_fare']);
    final platformFee = _num(s['platform_fee']);
    final netPayout = _num(s['net_payout']);
    // Fallback for rows created before `net_payout` existed: `total_payout`
    // held the value the rider earned, which isn't the farmer's net — but
    // it's still the only number we have, so use it as a best-effort net.
    final fallbackPayout = _num(s['total_payout']);
    final status = (s['status'] ?? 'PENDING').toString();
    final createdAt = s['created_at'];

    return _SettlementCard(
      cropName: cropName,
      quantityKg: quantityKg,
      grossAmount: grossAmount,
      riderFare: riderFare,
      platformFee: platformFee,
      netPayout: netPayout ?? fallbackPayout,
      isNetEstimated: netPayout == null && fallbackPayout != null,
      status: status,
      dateLabel: _shortDate(createdAt),
      rupees: _rupees,
    );
  }
}

// ---------------------------------------------------------------------------
// Financial summary card
// ---------------------------------------------------------------------------

class _FinancialSummaryCard extends StatelessWidget {
  const _FinancialSummaryCard({required this.totalNetSales});

  final double totalNetSales;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Local formatting — kept simple (no Indian grouping) because this
    // widget only renders once and duplicating the grouping helper is
    // cheaper than threading a callback through.
    final amountLabel = '₹${totalNetSales.round()}';

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _kFarmerGreen.withOpacity(0.15),
            _kFarmerGreen.withOpacity(0.05),
          ],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _kFarmerGreen.withOpacity(0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.account_balance_wallet,
                  color: _kFarmerGreen, size: 22),
              const SizedBox(width: 8),
              Text(
                'Total Net Sales',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: _kFarmerGreen,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            amountLabel,
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: _kFarmerGreen,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Sum of credited payouts after transport & platform fees',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, required this.count});

  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        if (count > 0)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: _kFarmerGreen.withOpacity(0.1),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              '$count',
              style: const TextStyle(
                color: _kFarmerGreen,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Settlement card
// ---------------------------------------------------------------------------

class _SettlementCard extends StatelessWidget {
  const _SettlementCard({
    required this.cropName,
    required this.quantityKg,
    required this.grossAmount,
    required this.riderFare,
    required this.platformFee,
    required this.netPayout,
    required this.isNetEstimated,
    required this.status,
    required this.dateLabel,
    required this.rupees,
  });

  final String cropName;
  final double? quantityKg;
  final double? grossAmount;
  final double? riderFare;
  final double? platformFee;
  final double? netPayout;

  /// True when `net_payout` wasn't on the row and we fell back to
  /// `total_payout` — the tile adds a small "estimated" hint so the farmer
  /// isn't misled by the number.
  final bool isNetEstimated;

  final String status;
  final String dateLabel;

  /// Passed in so this widget shares the parent's Indian-grouping
  /// formatter rather than duplicating it.
  final String Function(num?) rupees;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final headerCrop = cropName.isEmpty ? 'Crop' : cropName;
    final qtyLabel = quantityKg == null
        ? '—'
        : '${quantityKg!.round()} kg';
    final header = '$headerCrop • $qtyLabel';

    final grossKnown = grossAmount != null;
    final anyBreakdown =
        grossAmount != null || riderFare != null || platformFee != null;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ----- Header: crop + qty | status ---------------------------
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  header,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _SettlementStatusBadge(status: status),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            dateLabel,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 14),

          // ----- Breakdown --------------------------------------------
          if (!anyBreakdown)
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 12, vertical: 10,
              ),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(Icons.hourglass_empty,
                      size: 16, color: Colors.grey.shade700),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Pending Calculation — breakdown not yet available.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.grey.shade800,
                      ),
                    ),
                  ),
                ],
              ),
            )
          else ...[
            _AmountRow(
              label: 'Gross Sale Amount',
              value: grossKnown ? rupees(grossAmount) : 'Pending Calculation',
              valueColor: grossKnown
                  ? theme.colorScheme.onSurface
                  : Colors.grey.shade600,
            ),
            const SizedBox(height: 6),
            _AmountRow(
              label: 'Transport Fee',
              value: riderFare == null ? '—' : '- ${rupees(riderFare)}',
              valueColor: Colors.red.shade700,
            ),
            const SizedBox(height: 6),
            _AmountRow(
              label: 'Platform Fee',
              value: platformFee == null ? '—' : '- ${rupees(platformFee)}',
              valueColor: Colors.red.shade700,
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Divider(height: 1),
            ),
            _AmountRow(
              label: 'Net Credited Payout',
              value: netPayout == null ? '—' : rupees(netPayout),
              valueColor: _kFarmerGreen,
              bold: true,
              trailingHint: isNetEstimated ? 'estimated' : null,
            ),
          ],
        ],
      ),
    );
  }
}

class _AmountRow extends StatelessWidget {
  const _AmountRow({
    required this.label,
    required this.value,
    required this.valueColor,
    this.bold = false,
    this.trailingHint,
  });

  final String label;
  final String value;
  final Color valueColor;
  final bool bold;
  final String? trailingHint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: bold ? FontWeight.bold : FontWeight.w600,
                color: valueColor,
              ),
            ),
            if (trailingHint != null)
              Text(
                trailingHint!,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 10,
                  color: theme.colorScheme.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _SettlementStatusBadge extends StatelessWidget {
  const _SettlementStatusBadge({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final normalized = status.toUpperCase();

    final Color fg;
    final Color bg;
    switch (normalized) {
      case 'PAID':
        fg = _kFarmerGreen;
        bg = _kFarmerGreen.withOpacity(0.12);
        break;
      case 'PENDING':
        fg = Colors.amber.shade900;
        bg = Colors.amber.withOpacity(0.15);
        break;
      default:
        fg = Colors.black54;
        bg = Colors.black12;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: fg),
      ),
      child: Text(
        normalized,
        style: TextStyle(
          color: fg,
          fontWeight: FontWeight.bold,
          fontSize: 10,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Empty & error states
// ---------------------------------------------------------------------------

class _EmptyEarningsState extends StatelessWidget {
  const _EmptyEarningsState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.4),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        children: [
          Icon(Icons.receipt_long_outlined,
              size: 56, color: Colors.grey.shade400),
          const SizedBox(height: 12),
          Text(
            'No sales settlements found',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Completed deliveries and their mandi payouts will appear here '
            'once the trip is settled.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_rounded,
                size: 56, color: theme.colorScheme.error),
            const SizedBox(height: 16),
            Text(
              'Could not load earnings',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}