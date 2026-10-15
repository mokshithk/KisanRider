import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import 'order_detail_screen.dart';

/// Base URL of the FastAPI backend.
///
/// - Web/Chrome uses `localhost`.
/// - Physical Android/iOS devices use your laptop's Wi-Fi IP.
String get _kApiBaseUrl {
  if (kIsWeb) return 'http://localhost:8000';
  return 'http://10.28.1.142:8000';
}

/// Brand green used across the farmer UI.
const Color _kFarmerGreen = Color(0xFF2E7D32);

// ============================================================================
// Model
// ============================================================================

/// One row of `GET /farmer/orders/history`.
///
/// Deliberately narrow — the list view renders only three lines per card,
/// and the backend sends exactly the fields those lines need. Full order
/// details come from `GET /farmer/orders/{id}`, which the detail screen
/// fetches separately on tap.
class OrderSummary {
  OrderSummary({
    required this.id,
    required this.cropName,
    required this.weightKg,
    required this.status,
    required this.createdAt,
    this.pickupVillage,
    this.mandiName,
    this.stallNumber,
  });

  factory OrderSummary.fromJson(Map<String, dynamic> json) {
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

    return OrderSummary(
      id: (json['id'] ?? '').toString(),
      cropName: (json['crop_name'] ?? '—').toString(),
      weightKg: ((json['weight_kg'] ?? 0) as num).toDouble(),
      status: (json['status'] ?? 'PENDING').toString(),
      createdAt: parsedCreatedAt,
      pickupVillage: (json['pickup_village'] as String?)?.trim(),
      mandiName: (json['mandi_name'] as String?)?.trim(),
      stallNumber: (json['stall_number'] as String?)?.trim(),
    );
  }

  final String id;
  final String cropName;
  final double weightKg;

  /// Normalized backend status: PENDING / IN_TRANSIT / COMPLETED / CANCELLED.
  final String status;

  final DateTime createdAt;

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
    return '#KR-${take.toUpperCase()}';
  }
}

// ============================================================================
// Screen
// ============================================================================

/// Order History list — the farmer's past shipments in a compact
/// three-line-per-card feed. Tapping any card pushes the full
/// [OrderDetailScreen] for that order.
///
/// Fetches `GET /farmer/orders/history` on mount and on every
/// pull-to-refresh.
class OrderHistoryScreen extends StatefulWidget {
  const OrderHistoryScreen({super.key});

  @override
  State<OrderHistoryScreen> createState() => _OrderHistoryScreenState();
}

class _OrderHistoryScreenState extends State<OrderHistoryScreen> {
  List<OrderSummary> _orders = [];
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
        Uri.parse('$_kApiBaseUrl/farmer/orders/history'),
        headers: _headers(auth),
      );
      if (!mounted) return;

      if (response.statusCode == 200) {
        final List<dynamic> decoded =
            jsonDecode(response.body) as List<dynamic>;
        setState(() {
          _orders = decoded
              .whereType<Map<String, dynamic>>()
              .map(OrderSummary.fromJson)
              .toList(growable: false);
          _isLoading = false;
        });
      } else {
        setState(() {
          _error = _extractError(response) ??
              'Failed to load order history '
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

  void _openDetail(OrderSummary order) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => OrderDetailScreen(orderId: order.id),
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
        title: const Text('Order History'),
        backgroundColor: _kFarmerGreen,
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

    if (_orders.isEmpty) {
      return RefreshIndicator(
        onRefresh: _fetch,
        color: _kFarmerGreen,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 80),
          children: [
            Icon(
              Icons.receipt_long_outlined,
              size: 64,
              color: Colors.grey.shade400,
            ),
            const SizedBox(height: 16),
            const Center(
              child: Text(
                'No past orders yet.',
                style: TextStyle(fontSize: 15, color: Colors.black54),
              ),
            ),
            const SizedBox(height: 6),
            Center(
              child: Text(
                'Completed and in-flight shipments will appear here.',
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
      color: _kFarmerGreen,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        itemCount: _orders.length,
        itemBuilder: (context, index) {
          final order = _orders[index];
          return _OrderSummaryCard(
            order: order,
            onTap: () => _openDetail(order),
          );
        },
      ),
    );
  }
}

// ============================================================================
// Summary card — exactly 3 lines
// ============================================================================

class _OrderSummaryCard extends StatelessWidget {
  const _OrderSummaryCard({required this.order, required this.onTap});

  final OrderSummary order;
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Line 1: crop · weight  |  status badge
    final header =
        '${order.cropName} · ${order.weightKg.toStringAsFixed(0)} kg';

    // Line 2: date · short reference
    final subHeader = '${_formatDate(order.createdAt)} · ${order.shortRef}';

    // Line 3: pickup village ➔ mandi [stall]
    final pickup = (order.pickupVillage ?? '').isEmpty
        ? '—'
        : order.pickupVillage!;
    final mandi =
        (order.mandiName ?? '').isEmpty ? '—' : order.mandiName!;
    final stall = order.stallNumber;
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
              // ----- Line 1: crop · weight + status ---------------------
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
                  _StatusBadge(status: order.status),
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
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// Status badge
// ============================================================================

/// Status pill matching the vocabulary the backend normalizes to:
/// COMPLETED / CANCELLED / IN_TRANSIT / PENDING. Unknown values render
/// grey rather than crashing.
class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final String status;

  static const Map<String, (Color, Color)> _colors = {
    'COMPLETED':  (Color(0xFF166534), Color(0x2616A34A)), // green
    'CANCELLED':  (Color(0xFF991B1B), Color(0x26DC2626)), // red
    'IN_TRANSIT': (Color(0xFF6D28D9), Color(0x266D28D9)), // purple
    'PENDING':    (Color(0xFFB45309), Color(0x26F59E0B)), // amber
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
        // Replace underscores so IN_TRANSIT renders as "IN TRANSIT".
        normalized.replaceAll('_', ' '),
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
              'Could not load order history',
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