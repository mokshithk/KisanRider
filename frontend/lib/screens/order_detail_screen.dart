import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../providers/auth_provider.dart';

/// Base URL of the FastAPI backend.
String get _kApiBaseUrl {
  if (kIsWeb) return 'http://localhost:8000';
  return 'http://10.28.1.142:8000';
}

/// Brand green used across the farmer UI.
const Color _kFarmerGreen = Color(0xFF2E7D32);

// ============================================================================
// Models
// ============================================================================

class OrderDetail {
  OrderDetail({
    required this.id,
    required this.status,
    required this.createdAt,
    required this.pickup,
    required this.dropoff,
    required this.crop,
    this.tripStatus,
    this.completedAt,
    this.tripId,
    this.pickupOtp,
    this.rider,
    this.settlement,
  });

  factory OrderDetail.fromJson(Map<String, dynamic> json) {
    return OrderDetail(
      id: (json['id'] ?? '').toString(),
      status: (json['status'] ?? 'PENDING').toString(),
      tripStatus: json['trip_status']?.toString(),
      createdAt: _parseDate(json['created_at']) ?? DateTime.now(),
      completedAt: _parseDate(json['completed_at']),
      tripId: json['trip_id']?.toString(),
      pickupOtp: json['pickup_otp']?.toString(),
      rider: json['rider'] is Map<String, dynamic>
          ? RiderInfo.fromJson(json['rider'] as Map<String, dynamic>)
          : null,
      pickup: LocationInfo.fromJson(
          (json['pickup'] as Map<String, dynamic>?) ?? const {}),
      dropoff: LocationInfo.fromJson(
          (json['dropoff'] as Map<String, dynamic>?) ?? const {}),
      crop: CropInfo.fromJson(
          (json['crop'] as Map<String, dynamic>?) ?? const {}),
      settlement: json['settlement'] is Map<String, dynamic>
          ? SettlementInfo.fromJson(
              json['settlement'] as Map<String, dynamic>)
          : null,
    );
  }

  final String id;

  /// Normalized status: PENDING / IN_TRANSIT / COMPLETED / CANCELLED.
  final String status;

  /// Raw Trip.status (ACCEPTED / PICKED_UP / DELIVERED / CANCELLED) or
  /// null when the order is still PENDING. Used by the timeline to
  /// distinguish "rider assigned" from "in transit".
  final String? tripStatus;

  final DateTime createdAt;
  final DateTime? completedAt;
  final String? tripId;
  final String? pickupOtp;

  final RiderInfo? rider;
  final LocationInfo pickup;
  final LocationInfo dropoff;
  final CropInfo crop;
  final SettlementInfo? settlement;

  bool get hasRider => rider != null;
  bool get hasSettlement => settlement != null;

  static DateTime? _parseDate(dynamic raw) {
    if (raw == null) return null;
    if (raw is String) return DateTime.tryParse(raw);
    return null;
  }
}

class RiderInfo {
  RiderInfo({
    required this.id,
    required this.fullName,
    this.phoneNumber,
    this.vehicleType,
    this.vehicleNumber,
  });

  factory RiderInfo.fromJson(Map<String, dynamic> json) {
    return RiderInfo(
      id: (json['id'] ?? '').toString(),
      fullName: (json['full_name'] ?? '—').toString(),
      phoneNumber: json['phone_number']?.toString(),
      vehicleType: json['vehicle_type']?.toString(),
      vehicleNumber: json['vehicle_number']?.toString(),
    );
  }

  final String id;
  final String fullName;
  final String? phoneNumber;
  final String? vehicleType;
  final String? vehicleNumber;

  bool get hasPhone =>
      phoneNumber != null && phoneNumber!.trim().isNotEmpty;
}

class LocationInfo {
  LocationInfo({this.address, this.landmark, this.latitude, this.longitude});

  factory LocationInfo.fromJson(Map<String, dynamic> json) {
    return LocationInfo(
      address: json['address']?.toString(),
      landmark: json['landmark']?.toString(),
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
    );
  }

  final String? address;
  final String? landmark;
  final double? latitude;
  final double? longitude;

  bool get hasAddress => address != null && address!.trim().isNotEmpty;
  bool get hasLandmark => landmark != null && landmark!.trim().isNotEmpty;
  bool get hasCoords => latitude != null && longitude != null;

  String get displayAddress {
    if (hasAddress) return address!.trim();
    if (hasCoords) {
      return '${latitude!.toStringAsFixed(4)}, '
          '${longitude!.toStringAsFixed(4)}';
    }
    return '—';
  }
}

class CropInfo {
  CropInfo({
    required this.cropName,
    required this.weightKg,
  });

  factory CropInfo.fromJson(Map<String, dynamic> json) {
    return CropInfo(
      cropName: (json['crop_name'] ?? '—').toString(),
      weightKg: ((json['weight_kg'] ?? 0) as num).toDouble(),
    );
  }

  final String cropName;
  final double weightKg;
}

class SettlementInfo {
  SettlementInfo({
    required this.status,
    this.grossAmount,
    this.riderFare,
    this.platformFee,
    this.netPayout,
    this.createdAt,
  });

  factory SettlementInfo.fromJson(Map<String, dynamic> json) {
    return SettlementInfo(
      status: (json['status'] ?? 'PENDING').toString(),
      grossAmount: (json['gross_amount'] as num?)?.toDouble(),
      riderFare: (json['rider_fare'] as num?)?.toDouble(),
      platformFee: (json['platform_fee'] as num?)?.toDouble(),
      netPayout: (json['net_payout'] as num?)?.toDouble(),
      createdAt: json['created_at'] is String
          ? DateTime.tryParse(json['created_at'] as String)
          : null,
    );
  }

  final String status;
  final double? grossAmount;
  final double? riderFare;
  final double? platformFee;
  final double? netPayout;
  final DateTime? createdAt;

  /// The Settlement model uses PAID; the client-facing label is SETTLED.
  /// We map here so the UI reads consistently without backend changes.
  String get displayStatus {
    final s = status.toUpperCase();
    if (s == 'PAID') return 'SETTLED';
    return s;
  }
}

// ============================================================================
// Screen
// ============================================================================

/// Full-detail view for a single order. Fetches
/// `GET /farmer/orders/{order_id}` on mount and on pull-to-refresh, then
/// renders five sections top-to-bottom:
///
///   1. Header — reference, date, status chip.
///   2. Status Timeline — 4-step visual indicator.
///   3. Rider & Vehicle — name, phone (with call button), vehicle type,
///      license plate.
///   4. Location Details — pickup and dropoff blocks.
///   5. Crop Details — crop and weight.
///   6. Financial Breakdown — gross, transport fee, platform fee,
///      net payout, settlement status.
class OrderDetailScreen extends StatefulWidget {
  const OrderDetailScreen({super.key, required this.orderId});

  final String orderId;

  @override
  State<OrderDetailScreen> createState() => _OrderDetailScreenState();
}

class _OrderDetailScreenState extends State<OrderDetailScreen> {
  OrderDetail? _order;
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
        Uri.parse('$_kApiBaseUrl/farmer/orders/${widget.orderId}'),
        headers: _headers(auth),
      );
      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() {
          _order = OrderDetail.fromJson(data);
          _isLoading = false;
        });
      } else if (response.statusCode == 404) {
        setState(() {
          _error = 'Order not found.';
          _isLoading = false;
        });
      } else {
        setState(() {
          _error = _extractError(response) ??
              'Failed to load order (HTTP ${response.statusCode}).';
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
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade50,
      appBar: AppBar(
        title: const Text('Order Details'),
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

    if (_error != null || _order == null) {
      return _ErrorView(
        message: _error ?? 'Could not load order.',
        onRetry: _fetch,
      );
    }

    final order = _order!;
    return RefreshIndicator(
      onRefresh: _fetch,
      color: _kFarmerGreen,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          _HeaderCard(order: order),
          const SizedBox(height: 16),
          _StatusTimelineCard(order: order),
          const SizedBox(height: 16),
          if (order.hasRider) ...[
            _RiderCard(rider: order.rider!),
            const SizedBox(height: 16),
          ],
          _LocationCard(pickup: order.pickup, dropoff: order.dropoff),
          const SizedBox(height: 16),
          _CropCard(crop: order.crop),
          const SizedBox(height: 16),
          _FinancialCard(settlement: order.settlement),
        ],
      ),
    );
  }
}

// ============================================================================
// Section 1 — Header card (reference, date, status)
// ============================================================================

class _HeaderCard extends StatelessWidget {
  const _HeaderCard({required this.order});

  final OrderDetail order;

  static const List<String> _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  String _formatDate(DateTime d) {
    final local = d.toLocal();
    return '${local.day} ${_months[local.month - 1]} ${local.year}';
  }

  String get _shortRef {
    final compact = order.id.replaceAll('-', '');
    final take = compact.length >= 6 ? compact.substring(0, 6) : compact;
    return '#KR-${take.toUpperCase()}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _kFarmerGreen.withOpacity(0.10),
            _kFarmerGreen.withOpacity(0.03),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _kFarmerGreen.withOpacity(0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Order $_shortRef',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              _StatusBadge(status: order.status),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Placed on ${_formatDate(order.createdAt)}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (order.completedAt != null) ...[
            const SizedBox(height: 2),
            Text(
              'Completed on ${_formatDate(order.completedAt!)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ============================================================================
// Section 2 — Status timeline
// ============================================================================

class _StatusTimelineCard extends StatelessWidget {
  const _StatusTimelineCard({required this.order});

  final OrderDetail order;

  @override
  Widget build(BuildContext context) {
    // Timeline is derived from the raw trip status when available, so
    // ACCEPTED and PICKED_UP render as different steps even though both
    // normalize to "IN_TRANSIT" on the summary card.
    final trip = order.tripStatus;

    // Cancellation short-circuits the whole timeline: nothing past
    // "Order Placed" should render as completed.
    final cancelled = order.status == 'CANCELLED';

    final steps = <_TimelineStepData>[
      _TimelineStepData(
        label: 'Order Placed',
        done: true,
      ),
      _TimelineStepData(
        label: 'Rider Assigned',
        done: !cancelled &&
            (trip == 'ACCEPTED' ||
                trip == 'PICKED_UP' ||
                trip == 'DELIVERED'),
      ),
      _TimelineStepData(
        label: 'In Transit',
        done: !cancelled && (trip == 'PICKED_UP' || trip == 'DELIVERED'),
      ),
      _TimelineStepData(
        label: 'Delivered',
        done: !cancelled && trip == 'DELIVERED',
      ),
    ];

    return _SectionCard(
      title: 'Order Status',
      icon: Icons.timeline_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (cancelled) ...[
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red.shade200),
              ),
              child: Row(
                children: [
                  Icon(Icons.cancel_outlined,
                      size: 16, color: Colors.red.shade700),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'This order was cancelled.',
                      style: TextStyle(
                        color: Colors.red.shade800,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          for (int i = 0; i < steps.length; i++)
            _TimelineRow(
              label: steps[i].label,
              done: steps[i].done,
              isLast: i == steps.length - 1,
            ),
        ],
      ),
    );
  }
}

class _TimelineStepData {
  _TimelineStepData({required this.label, required this.done});
  final String label;
  final bool done;
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({
    required this.label,
    required this.done,
    required this.isLast,
  });

  final String label;
  final bool done;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = done ? _kFarmerGreen : Colors.grey.shade400;

    return SizedBox(
      height: 44,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 24,
            child: Column(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: done ? _kFarmerGreen : Colors.white,
                    shape: BoxShape.circle,
                    border: Border.all(color: color, width: 2),
                  ),
                  child: done
                      ? const Icon(Icons.check,
                          size: 14, color: Colors.white)
                      : null,
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 2,
                      color: color.withOpacity(0.4),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: done ? FontWeight.w600 : FontWeight.normal,
                color: done ? Colors.black87 : Colors.black54,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// Section 3 — Rider & vehicle
// ============================================================================

class _RiderCard extends StatelessWidget {
  const _RiderCard({required this.rider});

  final RiderInfo rider;

  Future<void> _call(BuildContext context) async {
    final cleaned = rider.phoneNumber?.replaceAll(RegExp(r'[^\d+]'), '');
    if (cleaned == null || cleaned.isEmpty) return;

    final uri = Uri(scheme: 'tel', path: cleaned);
    try {
      final ok = await launchUrl(uri);
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final vehicleType = (rider.vehicleType ?? '').trim();
    final vehicleNumber = (rider.vehicleNumber ?? '').trim();

    return _SectionCard(
      title: 'Rider & Vehicle',
      icon: Icons.delivery_dining,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DetailRow(label: 'Rider Name', value: rider.fullName),
          _DetailRow(
            label: 'Phone',
            value: rider.hasPhone ? '+91 ${rider.phoneNumber}' : '—',
          ),
          _DetailRow(
            label: 'Vehicle Type',
            value: vehicleType.isEmpty ? '—' : vehicleType,
          ),
          _DetailRow(
            label: 'License Plate',
            value: vehicleNumber.isEmpty ? '—' : vehicleNumber,
          ),
          if (rider.hasPhone) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => _call(context),
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
        ],
      ),
    );
  }
}

// ============================================================================
// Section 4 — Locations
// ============================================================================

class _LocationCard extends StatelessWidget {
  const _LocationCard({required this.pickup, required this.dropoff});

  final LocationInfo pickup;
  final LocationInfo dropoff;

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      title: 'Location Details',
      icon: Icons.location_on_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SubHeading(text: 'PICKUP'),
          const SizedBox(height: 6),
          _DetailRow(label: 'Address', value: pickup.displayAddress),
          if (pickup.hasLandmark)
            _DetailRow(label: 'Landmark', value: pickup.landmark!.trim()),
          if (pickup.hasCoords)
            _DetailRow(
              label: 'Coordinates',
              value: '${pickup.latitude!.toStringAsFixed(4)}, '
                  '${pickup.longitude!.toStringAsFixed(4)}',
            ),
          const SizedBox(height: 14),
          const _SubHeading(text: 'DROPOFF'),
          const SizedBox(height: 6),
          _DetailRow(label: 'Address', value: dropoff.displayAddress),
          if (dropoff.hasLandmark)
            _DetailRow(label: 'Landmark', value: dropoff.landmark!.trim()),
          if (dropoff.hasCoords)
            _DetailRow(
              label: 'Coordinates',
              value: '${dropoff.latitude!.toStringAsFixed(4)}, '
                  '${dropoff.longitude!.toStringAsFixed(4)}',
            ),
        ],
      ),
    );
  }
}

class _SubHeading extends StatelessWidget {
  const _SubHeading({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: Color(0xFF6B7280),
        letterSpacing: 1.2,
      ),
    );
  }
}

// ============================================================================
// Section 5 — Crop details
// ============================================================================

class _CropCard extends StatelessWidget {
  const _CropCard({required this.crop});

  final CropInfo crop;

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      title: 'Crop Details',
      icon: Icons.eco_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DetailRow(label: 'Crop', value: crop.cropName),
          _DetailRow(
            label: 'Weight',
            value: '${crop.weightKg.toStringAsFixed(0)} kg',
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// Section 6 — Financial breakdown
// ============================================================================

class _FinancialCard extends StatelessWidget {
  const _FinancialCard({required this.settlement});

  final SettlementInfo? settlement;

  /// Indian-style digit grouping: 12,34,567 not 1,234,567.
  static String _rupees(double? amount) {
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (settlement == null) {
      return _SectionCard(
        title: 'Financial Breakdown',
        icon: Icons.account_balance_wallet_outlined,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
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
                  'Settlement will be created once the delivery is '
                  'completed.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.grey.shade800,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final s = settlement!;
    final statusColor = s.displayStatus == 'SETTLED'
        ? _kFarmerGreen
        : Colors.amber.shade900;
    final statusBg = s.displayStatus == 'SETTLED'
        ? _kFarmerGreen.withOpacity(0.12)
        : Colors.amber.withOpacity(0.15);

    return _SectionCard(
      title: 'Financial Breakdown',
      icon: Icons.account_balance_wallet_outlined,
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          color: statusBg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: statusColor),
        ),
        child: Text(
          s.displayStatus,
          style: TextStyle(
            color: statusColor,
            fontWeight: FontWeight.bold,
            fontSize: 10,
            letterSpacing: 0.5,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DetailRow(
            label: 'Gross Sale Amount',
            value: s.grossAmount == null
                ? 'Pending Calculation'
                : _rupees(s.grossAmount),
          ),
          _DetailRow(
            label: 'Transport Fee',
            value: s.riderFare == null
                ? '—'
                : '- ${_rupees(s.riderFare)}',
            valueColor: Colors.red.shade700,
          ),
          _DetailRow(
            label: 'Platform Fee',
            value: s.platformFee == null
                ? '—'
                : '- ${_rupees(s.platformFee)}',
            valueColor: Colors.red.shade700,
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Divider(height: 1),
          ),
          _DetailRow(
            label: 'Net Payout',
            value: _rupees(s.netPayout),
            valueColor: _kFarmerGreen,
            bold: true,
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// Shared primitives
// ============================================================================

/// Card wrapper with a title row and an optional trailing widget. Used by
/// every section on this screen so the visual rhythm stays consistent.
class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.child,
    this.icon,
    this.trailing,
  });

  final String title;
  final Widget child;
  final IconData? icon;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 18, color: _kFarmerGreen),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

/// Label / value row used across every section. Fixed-width label column
/// keeps the values visually aligned down the card.
class _DetailRow extends StatelessWidget {
  const _DetailRow({
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
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: bold ? FontWeight.bold : FontWeight.w500,
                color: valueColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Status pill matching the normalized status vocabulary.
class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final String status;

  static const Map<String, (Color, Color)> _colors = {
    'COMPLETED':  (Color(0xFF166534), Color(0x2616A34A)),
    'CANCELLED':  (Color(0xFF991B1B), Color(0x26DC2626)),
    'IN_TRANSIT': (Color(0xFF6D28D9), Color(0x266D28D9)),
    'PENDING':    (Color(0xFFB45309), Color(0x26F59E0B)),
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
              'Could not load order',
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