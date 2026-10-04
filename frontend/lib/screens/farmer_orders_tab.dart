import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

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

// ---------------------------------------------------------------------------
// Phone call helper
// ---------------------------------------------------------------------------

/// Opens the platform's phone dialer pre-filled with [phone]. Mirrors the
/// `launchPhoneCall` helper in `rider_common.dart` — kept local rather than
/// imported so the farmer side doesn't pull in the rider module's other
/// dependencies (Map launcher, OTP enum, rider models).
Future<void> _launchPhoneCall(BuildContext context, String phone) async {
  final cleaned = phone.replaceAll(RegExp(r'[^\d+]'), '');
  if (cleaned.isEmpty) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No phone number available')),
      );
    }
    return;
  }

  final Uri url = Uri(scheme: 'tel', path: cleaned);

  try {
    final ok = await launchUrl(url);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open dialer for $cleaned')),
      );
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the phone dialer')),
      );
    }
  }
}

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

/// One entry from `GET /produce-requests/farmer/me`.
///
/// The backend nests a `trip` object once a rider has accepted. Its `rider`
/// sub-object carries the assigned rider's identity; the exact fields
/// returned depend on how `RiderSummary` is shaped on the backend:
///
///   - `full_name` and `phone` are always present.
///   - `phone_number`, `vehicle_number`, and `vehicle_type` are read
///     defensively — they aren't currently on `RiderSummary`, but the model
///     picks them up automatically if you extend the backend to include them.
///     Until then, the assigned-rider card renders "—" for the vehicle
///     fields and prefers `phone_number` over the legacy `phone` when both
///     are present.
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
    this.vehicleNumber,
    this.vehicleType,
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
      parsedCreatedAt = DateTime.tryParse(rawCreated) ??
          DateTime.fromMillisecondsSinceEpoch(0);
    } else {
      parsedCreatedAt = DateTime.fromMillisecondsSinceEpoch(0);
    }

    // Prefer the modern `phone_number` (contact field) over the legacy
    // `phone` (login identifier) when both are present. The legacy field is
    // only populated for accounts created before the email-OTP signup flow.
    final rawPhone = (rider?['phone_number'] ?? rider?['phone'])?.toString();

    return FarmerOrder(
      id: (json['id'] ?? '').toString(),
      cropType: (json['crop_type'] ?? '') as String,
      crateCount: ((json['crate_count'] ?? 0) as num).toInt(),
      status: (json['status'] ?? 'PENDING') as String,
      createdAt: parsedCreatedAt,
      dropoffLocation: json['dropoff_location'] as String?,
      pickupOtp: json['pickup_otp']?.toString(),
      riderName: rider?['full_name'] as String?,
      riderPhone: (rawPhone == null || rawPhone.isEmpty) ? null : rawPhone,
      vehicleNumber: rider?['vehicle_number'] as String?,
      vehicleType: rider?['vehicle_type'] as String?,
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
  final String? vehicleNumber;
  final String? vehicleType;

  bool get isPending => status == 'PENDING';

  /// True when a rider has been assigned and the handoff hasn't completed
  /// yet. Matches the backend's active trip statuses (ACCEPTED and the
  /// variants of "in transit" the system uses). Kept as a getter so the
  /// status set lives in one place.
  bool get isActive =>
      status == 'ACCEPTED' || status == 'PICKED_UP' || status == 'IN_TRANSIT';

  bool get hasRider => riderName != null && riderName!.isNotEmpty;

  bool get hasRiderPhone => riderPhone != null && riderPhone!.isNotEmpty;
}

// ---------------------------------------------------------------------------
// Tab
// ---------------------------------------------------------------------------

/// My Orders tab: fetches the farmer's produce requests and lists them as
/// cards, newest first. Pull-to-refresh re-fetches. Empty state offers a
/// shortcut into the Book Transport tab via [onBookTransport].
///
/// ## Conditional rendering
///
/// Each card reflects the order's lifecycle:
///   - PENDING: shows "Searching for nearby Rider…" and no rider section.
///   - ACCEPTED / PICKED_UP / IN_TRANSIT: shows the assigned-rider card
///     with name, vehicle info, and a CALL RIDER button.
///   - DELIVERED / COMPLETED / CANCELLED: no rider section — the trip is over.
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

        // Newest first.
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

            // ----- PENDING: search-in-progress notice ---------------------
            // Rendered instead of the assigned-rider card. Gives the farmer
            // a clear state indicator ("we're looking") rather than leaving
            // them wondering why no rider info is showing yet.
            if (order.isPending) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Colors.amber.shade50,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.amber.shade300),
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          Colors.amber.shade800,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Searching for nearby Rider…',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          color: Colors.amber.shade900,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // ----- ACCEPTED / PICKED_UP: assigned-rider card --------------
            // Shown only once a rider has been assigned and the trip is
            // still active. Includes the CALL RIDER button (only when a
            // phone number is on file) and the pickup OTP badge.
            if (order.isActive) ...[
              const SizedBox(height: 14),
              _AssignedRiderCard(order: order),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Assigned rider card
// ---------------------------------------------------------------------------

/// Card displayed inside an order while a rider is assigned and the trip is
/// still active. Shows rider identity, vehicle info, the CALL RIDER action,
/// and the pickup OTP the farmer reads out at handoff.
class _AssignedRiderCard extends StatelessWidget {
  const _AssignedRiderCard({required this.order});

  final FarmerOrder order;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Vehicle line — combines type and plate into one readable row.
    // Either piece can be missing; when both are, the row renders an em
    // dash so the layout stays consistent with the rest of the card.
    final vehicleParts = <String>[];
    if (order.vehicleType != null && order.vehicleType!.trim().isNotEmpty) {
      vehicleParts.add(order.vehicleType!.trim());
    }
    if (order.vehicleNumber != null && order.vehicleNumber!.trim().isNotEmpty) {
      vehicleParts.add('(${order.vehicleNumber!.trim()})');
    }
    final vehicleLine =
        vehicleParts.isEmpty ? '—' : vehicleParts.join(' ');

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _kFarmerGreen.withOpacity(0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _kFarmerGreen.withOpacity(0.30)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ----- Header ------------------------------------------------
          Row(
            children: [
              const Icon(Icons.delivery_dining,
                  color: _kFarmerGreen, size: 20),
              const SizedBox(width: 8),
              Text(
                'Assigned Rider',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: _kFarmerGreen,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // ----- Name --------------------------------------------------
          Row(
            children: [
              const Icon(Icons.person_outline,
                  size: 18, color: Colors.black54),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  order.hasRider ? order.riderName! : 'Rider assigned',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),

          // ----- Vehicle -----------------------------------------------
          Row(
            children: [
              const Icon(Icons.local_shipping_outlined,
                  size: 18, color: Colors.black54),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  vehicleLine,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),

          // ----- CALL RIDER button (only when a phone is on file) ------
          if (order.hasRiderPhone) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () =>
                    _launchPhoneCall(context, order.riderPhone!),
                style: FilledButton.styleFrom(
                  backgroundColor: _kFarmerGreen,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  textStyle: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
                icon: const Icon(Icons.phone, size: 18),
                label: const Text('CALL RIDER'),
              ),
            ),
          ],

          const SizedBox(height: 12),

          // ----- Pickup OTP badge --------------------------------------
          // Amber badge the farmer reads out to the rider at handoff.
          // Shown for any active trip; falls back to "----" if the backend
          // hasn't populated pickup_otp yet.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.amber.shade100,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(Icons.lock_outline,
                    size: 18, color: Colors.amber.shade900),
                const SizedBox(width: 8),
                Expanded(
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
            ),
          ),
        ],
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
    'IN_TRANSIT': (Color(0xFF6D28D9), Color(0x266D28D9)), // purple
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