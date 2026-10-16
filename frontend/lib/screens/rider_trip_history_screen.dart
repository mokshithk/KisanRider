import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import 'rider_trip_detail_screen.dart';

/// Base URL of the FastAPI backend.
///
/// - Web/Chrome uses `localhost`.
/// - Physical Android/iOS devices use your laptop's Wi-Fi IP.
String get _kApiBaseUrl {
  if (kIsWeb) return 'http://localhost:8000';
  return 'http://10.28.1.142:8000';
}

/// Brand green used across the rider UI.
const Color _kRiderGreen = Color(0xFF2E7D32);

// ============================================================================
// Model
// ============================================================================

/// One row of `GET /rider/trips/history`.
///
/// Deliberately narrow — the list view renders only four short lines per
/// card, and the backend sends exactly the fields those lines need. Full
/// trip details come from `GET /rider/trips/{id}`, which the detail
/// screen fetches separately on tap.
class RiderTripSummary {
  RiderTripSummary({
    required this.id,
    required this.cropName,
    required this.weightKg,
    required this.fareEarned,
    required this.status,
    required this.createdAt,
    required this.paymentMethod,
    this.pickupVillage,
    this.mandiName,
    this.stallNumber,
  });

  factory RiderTripSummary.fromJson(Map<String, dynamic> json) {
    // A malformed or missing created_at shouldn't crash the whole list.
    // Fall back to epoch so the row still renders (just at the bottom,
    // after the sort the backend already applied).
    DateTime parsedCreatedAt;
    final rawCreated = json['created_at'];
    if (rawCreated is String) {
      parsedCreatedAt = DateTime.tryParse(rawCreated) ??
          DateTime.fromMillisecondsSinceEpoch(0);
    } else {
      parsedCreatedAt = DateTime.fromMillisecondsSinceEpoch(0);
    }

    return RiderTripSummary(
      id: (json['id'] ?? '').toString(),
      cropName: (json['crop_name'] ?? '—').toString(),
      weightKg: ((json['weight_kg'] ?? 0) as num).toDouble(),
      fareEarned: ((json['fare_earned'] ?? 0) as num).toDouble(),
      status: (json['status'] ?? 'DELIVERED').toString(),
      createdAt: parsedCreatedAt,
      paymentMethod: (json['payment_method'] ?? '—').toString(),
      pickupVillage: (json['pickup_village'] as String?)?.trim(),
      mandiName: (json['mandi_name'] as String?)?.trim(),
      stallNumber: (json['stall_number'] as String?)?.trim(),
    );
  }

  final String id;
  final String cropName;
  final double weightKg;

  /// What the rider earned on this trip (Settlement.total_payout). Zero
  /// for cancelled trips.
  final double fareEarned;

  /// "DELIVERED" or "CANCELLED" — the only two statuses the backend
  /// surfaces on this endpoint.
  final String status;

  final DateTime createdAt;

  /// "Cash Collected", "Wallet Credited", or "—".
  final String paymentMethod;

  /// Derived server-side from the farmer's taluk/village or the first
  /// segment of the pickup address. May be null.
  final String? pickupVillage;

  /// Parsed server-side out of `dropoff_location` (formatted as
  /// "MandiName - StallInfo" by the booking form). Either may be null.
  final String? mandiName;
  final String? stallNumber;

  /// Short, human-friendly reference shown on the summary card.
  ///
  /// Derived from the UUID's first 6 hex characters, uppercased. Stable
  /// across sessions and doesn't expose the full id.
  String get shortRef {
    final compact = id.replaceAll('-', '');
    final take = compact.length >= 6 ? compact.substring(0, 6) : compact;
    return '#TRIP-${take.toUpperCase()}';
  }

  bool get isCancelled => status.toUpperCase() == 'CANCELLED';
}

// ============================================================================
// Screen
// ============================================================================

/// Trip History list — the rider's past deliveries and cancellations in
/// a compact four-line-per-card feed. Tapping any card pushes the full
/// [RiderTripDetailScreen] for that trip.
///
/// Fetches `GET /rider/trips/history` on mount and on every
/// pull-to-refresh.
class RiderTripHistoryScreen extends StatefulWidget {
  const RiderTripHistoryScreen({super.key});

  @override
  State<RiderTripHistoryScreen> createState() =>
      _RiderTripHistoryScreenState();
}

class _RiderTripHistoryScreenState extends State<RiderTripHistoryScreen> {
  List<RiderTripSummary> _trips = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _fetch());
  }

  // -------------------------------------------------------------------------
  // Networking
  // -------------------------------------------------------------------------

  Map<String, String> _headers(AuthProvider auth) => {
        'Authorization': 'Bearer ${auth.token}',
        'Accept': 'application/json',
      };

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
        Uri.parse('$_kApiBaseUrl/rider/trips/history'),
        headers: _headers(auth),
      );
      if (!mounted) return;

      if (response.statusCode == 200) {
        final List<dynamic> decoded =
            jsonDecode(response.body) as List<dynamic>;
        setState(() {
          _trips = decoded
              .whereType<Map<String, dynamic>>()
              .map(RiderTripSummary.fromJson)
              .toList(growable: false);
          _isLoading = false;
        });
      } else {
        setState(() {
          _error = _extractError(response) ??
              'Failed to load trip history '
              '(HTTP ${response.statusCode}).';
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
  // Navigation
  // -------------------------------------------------------------------------

  void _openDetail(RiderTripSummary trip) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RiderTripDetailScreen(tripId: trip.id),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade50,
      appBar: AppBar(
        title: const Text('Trip History'),
        backgroundColor: _kRiderGreen,
        foregroundColor: Colors.white,
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return _ErrorView(message: _error!, onRetry: _fetch);
    }

    if (_trips.isEmpty) {
      return RefreshIndicator(
        onRefresh: _fetch,
        color: _kRiderGreen,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 80),
          children: [
            Icon(
              Icons.history,
              size: 64,
              color: Colors.grey.shade400,
            ),
            const SizedBox(height: 16),
            const Center(
              child: Text(
                'No completed trips yet.',
                style: TextStyle(fontSize: 15, color: Colors.black54),
              ),
            ),
            const SizedBox(height: 6),
            Center(
              child: Text(
                'Delivered and cancelled trips will appear here once '
                'you start accepting requests.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _fetch,
      color: _kRiderGreen,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        itemCount: _trips.length,
        itemBuilder: (context, index) {
          final trip = _trips[index];
          return _TripSummaryCard(
            trip: trip,
            onTap: () => _openDetail(trip),
          );
        },
      ),
    );
  }
}

// ============================================================================
// Summary card — exactly 4 lines
// ============================================================================

class _TripSummaryCard extends StatelessWidget {
  const _TripSummaryCard({required this.trip, required this.onTap});

  final RiderTripSummary trip;
  final VoidCallback onTap;

  /// "12 Oct 2026" — three-letter month abbreviations so the string
  /// stays short enough that the date + ref line never wraps on a phone.
  static const List<String> _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  String _formatDate(DateTime d) {
    final local = d.toLocal();
    return '${local.day} ${_months[local.month - 1]} ${local.year}';
  }

  /// Indian-style digit grouping: 12,34,567 not 1,234,567. Whole rupees
  /// only — payouts are never fractional on this platform.
  static String _rupees(num amount) {
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Line 1a: crop · weight
    final header =
        '${trip.cropName} · ${trip.weightKg.toStringAsFixed(0)} kg';

    // Line 1b: fare — hidden for cancelled trips (no fare was earned).
    final fareLabel = trip.isCancelled
        ? '—'
        : '+${_rupees(trip.fareEarned)}';

    // Line 2: date · short reference
    final subHeader = '${_formatDate(trip.createdAt)} · ${trip.shortRef}';

    // Line 3: pickup village ➔ mandi [stall]
    final pickup = (trip.pickupVillage ?? '').isEmpty
        ? '—'
        : trip.pickupVillage!;
    final mandi =
        (trip.mandiName ?? '').isEmpty ? '—' : trip.mandiName!;
    final stall = trip.stallNumber;
    final destination =
        (stall == null || stall.isEmpty) ? mandi : '$mandi $stall';
    final route = '$pickup  ➔  $destination';

    return Card(
      elevation: 1,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ----- Line 1: crop · weight | fare | status --------------
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      header,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    fareLabel,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: trip.isCancelled
                          ? Colors.grey.shade500
                          : _kRiderGreen,
                    ),
                  ),
                  const SizedBox(width: 8),
                  _StatusBadge(status: trip.status),
                ],
              ),
              const SizedBox(height: 6),

              // ----- Line 2: date · reference ---------------------------
              Text(
                subHeader,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),

              // ----- Line 3: route --------------------------------------
              Text(
                route,
                style: theme.textTheme.bodyMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),

              // ----- Line 4: payment method tag -------------------------
              _PaymentMethodTag(method: trip.paymentMethod),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// Payment method tag
// ============================================================================

/// Small chip showing how the rider was (or will be) paid:
/// "Cash Collected", "Wallet Credited", or "—". Unknown values render
/// grey so an unexpected backend value doesn't break the layout.
class _PaymentMethodTag extends StatelessWidget {
  const _PaymentMethodTag({required this.method});

  final String method;

  @override
  Widget build(BuildContext context) {
    final normalized = method.toUpperCase();

    final Color fg;
    final Color bg;
    final IconData icon;

    switch (normalized) {
      case 'WALLET CREDITED':
        fg = _kRiderGreen;
        bg = _kRiderGreen.withOpacity(0.10);
        icon = Icons.account_balance_wallet_outlined;
        break;
      case 'CASH COLLECTED':
        fg = Colors.orange.shade900;
        bg = Colors.orange.withOpacity(0.12);
        icon = Icons.payments_outlined;
        break;
      default:
        fg = Colors.black54;
        bg = Colors.black12;
        icon = Icons.help_outline;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: fg.withOpacity(0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: fg),
          const SizedBox(width: 5),
          Text(
            method,
            style: TextStyle(
              color: fg,
              fontWeight: FontWeight.w700,
              fontSize: 11,
              letterSpacing: 0.4,
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// Status badge
// ============================================================================

/// Status pill matching the vocabulary the backend returns on this
/// endpoint: DELIVERED (green) or CANCELLED (red). Unknown values render
/// grey rather than crashing.
class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final String status;

  static const Map<String, (Color, Color)> _colors = {
    'DELIVERED': (Color(0xFF166534), Color(0x2616A34A)), // green
    'CANCELLED': (Color(0xFF991B1B), Color(0x26DC2626)), // red
  };

  @override
  Widget build(BuildContext context) {
    final normalized = status.toUpperCase();
    final (fg, bg) =
        _colors[normalized] ?? (Colors.black54, Colors.black12);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
          fontSize: 11,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

// ============================================================================
// Error view
// ============================================================================

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
              'Could not load trip history',
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