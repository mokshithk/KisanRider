import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import 'rider_common.dart';

/// Tab 2 of the rider shell — today's earnings summary plus the rider's
/// payout history from `GET /settlements/me`, newest first.
class RiderEarningsTab extends StatefulWidget {
  const RiderEarningsTab({super.key});

  @override
  State<RiderEarningsTab> createState() => _RiderEarningsTabState();
}

class _RiderEarningsTabState extends State<RiderEarningsTab>
    with AutomaticKeepAliveClientMixin {
  /// Raw settlement rows as returned by the backend. Kept as maps rather
  /// than typed models because the field set is small and stable, and the
  /// only derived value we compute (today's total) is easy to recompute
  /// from the maps without an intermediate class.
  List<Map<String, dynamic>> _settlements = [];

  bool _isLoading = true;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // Provider/context is only safe after the first frame.
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
        Uri.parse('$kApiBaseUrl/settlements/me'),
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
              'Failed to load earnings (HTTP ${response.statusCode}).';
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
  // Derived values
  // -------------------------------------------------------------------------

  /// Sum of `total_payout` for settlements whose `created_at` falls on the
  /// current local date. Malformed timestamps are silently skipped rather
  /// than crashing the whole sum.
  double get _todayEarnings {
    final now = DateTime.now();
    double sum = 0;
    for (final s in _settlements) {
      final raw = s['created_at'];
      if (raw is String) {
        final parsed = DateTime.tryParse(raw);
        if (parsed != null &&
            parsed.year == now.year &&
            parsed.month == now.month &&
            parsed.day == now.day) {
          sum += ((s['total_payout'] ?? 0) as num).toDouble();
        }
      }
    }
    return sum;
  }

  /// Formats a rupee amount with Indian grouping (12,34,567) rather than
  /// western (1,234,567). Whole rupees only — payouts are never fractional
  /// on this platform.
  String _formatRupees(double amount) {
    final n = amount.round();
    final sign = n < 0 ? '-' : '';
    final s = n.abs().toString();
    if (s.length <= 3) return '$sign₹$s';

    // Last three digits form the final group; everything to the left is
    // grouped in pairs (lakh, crore, ...).
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

  /// Human-friendly timestamp for a settlement row. Falls back to an em
  /// dash if the value is missing or unparseable.
  String _formatTimestamp(dynamic raw) {
    if (raw is! String) return '—';
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return '—';
    final local = parsed.toLocal();
    return '${local.day.toString().padLeft(2, '0')}/'
        '${local.month.toString().padLeft(2, '0')}/'
        '${local.year}  '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
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
      return ErrorView(message: _error!, onRetry: _fetch);
    }

    final theme = Theme.of(context);

    return RefreshIndicator(
      onRefresh: _fetch,
      color: kRiderGreen,
      child: ListView(
        // AlwaysScrollableScrollPhysics so pull-to-refresh still works when
        // the content is shorter than the viewport (e.g. empty state).
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          // ----- Today's Earnings header -------------------------------
          _EarningsHeader(
            formattedAmount: _formatRupees(_todayEarnings),
            completedTrips: _settlements.length,
          ),
          const SizedBox(height: 24),

          // ----- Section title -----------------------------------------
          Text(
            'Recent Trip History',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),

          // ----- List or empty state -----------------------------------
          if (_settlements.isEmpty)
            const _EmptyEarningsState()
          else
            ..._settlements.map(
              (s) => _SettlementTile(
                payoutLabel: _formatRupees(
                  ((s['total_payout'] ?? 0) as num).toDouble(),
                ),
                timestampLabel: _formatTimestamp(s['created_at']),
                status: (s['status'] ?? 'PENDING').toString(),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Header card
// ---------------------------------------------------------------------------

class _EarningsHeader extends StatelessWidget {
  const _EarningsHeader({
    required this.formattedAmount,
    required this.completedTrips,
  });

  final String formattedAmount;
  final int completedTrips;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            kRiderGreen.withOpacity(0.15),
            kRiderGreen.withOpacity(0.05),
          ],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: kRiderGreen.withOpacity(0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.account_balance_wallet,
                  color: kRiderGreen, size: 22),
              const SizedBox(width: 8),
              Text(
                'Today\'s Earnings',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: kRiderGreen,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            formattedAmount,
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: kRiderGreen,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '$completedTrips completed trip'
            '${completedTrips == 1 ? "" : "s"}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Settlement tile
// ---------------------------------------------------------------------------

class _SettlementTile extends StatelessWidget {
  const _SettlementTile({
    required this.payoutLabel,
    required this.timestampLabel,
    required this.status,
  });

  final String payoutLabel;
  final String timestampLabel;
  final String status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: kRiderGreen.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.currency_rupee,
                color: kRiderGreen, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  payoutLabel,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  timestampLabel,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          _SettlementStatusBadge(status: status),
        ],
      ),
    );
  }
}

/// Small chip showing PAID (green) / PENDING (amber). Anything else falls
/// back to grey so an unexpected status doesn't break the layout.
///
/// Deliberately separate from `StatusBadge` in rider_common: that one is
/// keyed on Trip statuses (ACCEPTED / PICKED_UP / DELIVERED / CANCELLED),
/// and settlement status is a different enum entirely.
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
        fg = kRiderGreen;
        bg = kRiderGreen.withOpacity(0.12);
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
// Empty state
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
            'No completed trips yet',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Completed deliveries will appear here along with their '
            'payout amounts.',
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