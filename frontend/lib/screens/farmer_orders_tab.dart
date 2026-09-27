import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';

/// Base URL of the FastAPI backend.
///
/// NOTE: `127.0.0.1` only works from Flutter Desktop / Chrome on the same
/// machine. On an Android emulator use `10.0.2.2`, on a physical device
/// use your machine's LAN IP.
const String _kApiBaseUrl = 'http://127.0.0.1:8000';

/// Brand green used across the farmer-side UI. Kept local so this file has
/// no dependency on farmer_dashboard.dart.
const Color _kFarmerGreen = Color(0xFF2E7D32);

/// One entry from `GET /produce-requests/farmer/me`.
///
/// The backend also nests a `trip` object once a rider has accepted, which
/// carries `trip.rider.full_name` / `trip.rider.phone`. All of that is
/// optional while the request is still PENDING.
class FarmerOrder {
  FarmerOrder({
    required this.id,
    required this.cropType,
    required this.crateCount,
    required this.status,
    required this.createdAt,
    this.dropoffLocation,
    this.pickupOtp,
    this.riderName,
    this.riderPhone,
  });

  factory FarmerOrder.fromJson(Map<String, dynamic> json) {
    final trip = json['trip'] as Map<String, dynamic>?;
    final rider = trip?['rider'] as Map<String, dynamic>?;

    // The backend serialises created_at as an ISO-8601 string. A malformed
    // or missing value shouldn't crash the whole list, so we fall back to
    // epoch (which just pushes that row to the bottom when sorting).
    DateTime parsedCreatedAt;
    final rawCreated = json['created_at'];
    if (rawCreated is String) {
      parsedCreatedAt =
          DateTime.tryParse(rawCreated) ?? DateTime.fromMillisecondsSinceEpoch(0);
    } else {
      parsedCreatedAt = DateTime.fromMillisecondsSinceEpoch(0);
    }

    return FarmerOrder(
      id: (json['id'] ?? '').toString(),
      cropType: (json['crop_type'] ?? '') as String,
      crateCount: ((json['crate_count'] ?? 0) as num).toInt(),
      status: (json['status'] ?? 'PENDING') as String,
      createdAt: parsedCreatedAt,
      dropoffLocation: json['dropoff_location'] as String?,
      pickupOtp: json['pickup_otp']?.toString(),
      riderName: rider?['full_name'] as String?,
      riderPhone: rider?['phone'] as String?,
    );
  }

  final String id;
  final String cropType;
  final int crateCount;
  final String status;
  final DateTime createdAt;
  final String? dropoffLocation;
  final String? pickupOtp;
  final String? riderName;
  final String? riderPhone;

  bool get isActive => status == 'ACCEPTED' || status == 'PICKED_UP';
  bool get hasRider => riderName != null && riderName!.isNotEmpty;
}

/// My Orders tab: fetches the farmer's produce requests and lists them as
/// cards, newest first. Pull-to-refresh re-fetches. Empty state offers a
/// shortcut into the Book Transport tab via [onBookTransport].
class FarmerOrdersTab extends StatefulWidget {
  const FarmerOrdersTab({
    super.key,
    required this.onBookTransport,
  });

  /// Invoked from the empty state's "Book Transport" button. The parent
  /// dashboard uses it to switch the bottom-nav index to tab 1.
  final VoidCallback onBookTransport;

  @override
  State<FarmerOrdersTab> createState() => _FarmerOrdersTabState();
}

class _FarmerOrdersTabState extends State<FarmerOrdersTab> {
  List<FarmerOrder> myRequests = [];
  bool isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Provider/context is only safe after the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => _fetchOrders());
  }

  Map<String, String> _headers(AuthProvider auth) {
    return {
      'Authorization': 'Bearer ${auth.token}',
      'Accept': 'application/json',
    };
  }

  Future<void> _fetchOrders() async {
    final auth = context.read<AuthProvider>();
    if (auth.token == null) {
      setState(() {
        isLoading = false;
        _error = 'Not signed in.';
      });
      return;
    }

    setState(() {
      isLoading = true;
      _error = null;
    });

    try {
      // The backend exposes this list at /produce-requests/farmer/me
      // (the /produce-requests/ path with no id isn't registered).
      final response = await http.get(
        Uri.parse('$_kApiBaseUrl/produce-requests/farmer/me'),
        headers: _headers(auth),
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        final List<dynamic> decoded =
            jsonDecode(response.body) as List<dynamic>;

        final parsed = decoded
            .whereType<Map<String, dynamic>>()
            .map(FarmerOrder.fromJson)
            .toList();

        // Newest first. The backend uses UUID primary keys, so sorting on
        // `id` numerically doesn't work — `created_at` is the correct key.
        parsed.sort((a, b) => b.createdAt.compareTo(a.createdAt));

        setState(() {
          myRequests = parsed;
          isLoading = false;
        });
      } else {
        setState(() {
          _error = _extractError(response) ??
              'Failed to load orders (HTTP ${response.statusCode}).';
          isLoading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Network error: $e';
        isLoading = false;
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

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return _OrdersErrorState(message: _error!, onRetry: _fetchOrders);
    }

    if (myRequests.isEmpty) {
      return RefreshIndicator(
        onRefresh: _fetchOrders,
        color: _kFarmerGreen,
        child: _OrdersEmptyState(onBookTransport: widget.onBookTransport),
      );
    }

    return RefreshIndicator(
      onRefresh: _fetchOrders,
      color: _kFarmerGreen,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        itemCount: myRequests.length,
        itemBuilder: (context, index) =>
            _OrderCard(order: myRequests[index]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Order card
// ---------------------------------------------------------------------------

class _OrderCard extends StatelessWidget {
  const _OrderCard({required this.order});

  final FarmerOrder order;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      elevation: 1,
      margin: const EdgeInsets.only(bottom: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ----- Header: crop • crates + status chip ---------------------
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    '${order.cropType} • ${order.crateCount} Crates',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _StatusChip(status: order.status),
              ],
            ),

            const SizedBox(height: 12),

            // ----- Dropoff location ---------------------------------------
            _InfoRow(
              icon: Icons.flag_outlined,
              label: 'Dropoff: '
                  '${(order.dropoffLocation ?? '').isEmpty ? "—" : order.dropoffLocation}',
            ),

            // ----- Rider + OTP (only for active trips) --------------------
            if (order.isActive) ...[
              const SizedBox(height: 14),
              const Divider(height: 1),
              const SizedBox(height: 14),
              Row(
                children: [
                  Icon(
                    Icons.delivery_dining,
                    size: 20,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      order.hasRider ? order.riderName! : 'Rider Assigned',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (order.riderPhone != null &&
                      order.riderPhone!.isNotEmpty)
                    IconButton(
                      tooltip: 'Call Rider',
                      icon: const Icon(Icons.call),
                      color: _kFarmerGreen,
                      onPressed: () {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Calling ${order.riderPhone}…'),
                          ),
                        );
                        // Wire up url_launcher:
                        // launchUrl(Uri.parse('tel:${order.riderPhone}'));
                      },
                    ),
                ],
              ),

              // Pickup OTP — prominent amber badge the farmer reads to the
              // rider at handoff. Shown for any active trip (ACCEPTED or
              // PICKED_UP); falls back to "----" if the backend hasn't
              // populated pickup_otp yet, so the layout stays consistent.
              const SizedBox(height: 12),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.amber.shade100,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Pickup OTP: ${order.pickupOtp ?? '----'}',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.amber.shade900,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: Text(label, style: theme.textTheme.bodyMedium),
        ),
      ],
    );
  }
}

/// Status -> color mapping. Unknown statuses render grey rather than
/// crashing.
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final String status;

  static const Map<String, (Color, Color)> _colors = {
    'PENDING': (Color(0xFFB45309), Color(0x26F59E0B)), // amber
    'ACCEPTED': (Color(0xFF1D4ED8), Color(0x261D4ED8)), // blue
    'PICKED_UP': (Color(0xFF6D28D9), Color(0x266D28D9)), // purple
    'DELIVERED': (Color(0xFF166534), Color(0x2616A34A)), // green
    'COMPLETED': (Color(0xFF166534), Color(0x2616A34A)), // green
    'CANCELLED': (Color(0xFF991B1B), Color(0x26DC2626)), // red
  };

  @override
  Widget build(BuildContext context) {
    final (fg, bg) =
        _colors[status.toUpperCase()] ?? (Colors.black54, Colors.black12);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: fg, width: 1),
      ),
      child: Text(
        status.toUpperCase(),
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

// ---------------------------------------------------------------------------
// Empty & error states
// ---------------------------------------------------------------------------

class _OrdersEmptyState extends StatelessWidget {
  const _OrdersEmptyState({required this.onBookTransport});

  final VoidCallback onBookTransport;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // ListView so RefreshIndicator has something scrollable to wrap even
    // when the content is short.
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 80),
      children: [
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: _kFarmerGreen.withOpacity(0.08),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.local_shipping_outlined,
            size: 64,
            color: _kFarmerGreen,
          ),
        ),
        const SizedBox(height: 24),
        Text(
          'No active shipments found.',
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Book transport to get started!',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: onBookTransport,
          style: FilledButton.styleFrom(
            backgroundColor: _kFarmerGreen,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          icon: const Icon(Icons.add),
          label: const Text('Book Transport'),
        ),
      ],
    );
  }
}

class _OrdersErrorState extends StatelessWidget {
  const _OrdersErrorState({required this.message, required this.onRetry});

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
              'Could not load orders',
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