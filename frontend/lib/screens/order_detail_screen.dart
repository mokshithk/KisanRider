import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../providers/auth_provider.dart';
import 'farmer_dashboard.dart';

/// Base URL of the FastAPI backend.
String get _kApiBaseUrl {
  if (kIsWeb) return 'http://localhost:8000';
  return 'http://10.28.1.142:8000';
}

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
    this.cancellationReason,
    this.rider,
    this.settlement,
    this.dropoffDistrict,
    this.dropoffMandiName,
    this.dropoffStallNumber,
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
      cancellationReason: json['cancellation_reason']?.toString(),
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
      dropoffDistrict: json['dropoff_district']?.toString(),
      dropoffMandiName: json['dropoff_mandi_name']?.toString(),
      dropoffStallNumber: json['dropoff_stall_number']?.toString(),
    );
  }

  final String id;
  final String status; // PENDING / IN_TRANSIT / COMPLETED / CANCELLED
  final String? tripStatus; // ACCEPTED / PICKED_UP / DELIVERED / CANCELLED
  final DateTime createdAt;
  final DateTime? completedAt;
  final String? tripId;
  final String? pickupOtp;
  final String? cancellationReason;

  final RiderInfo? rider;
  final LocationInfo pickup;
  final LocationInfo dropoff;
  final CropInfo crop;
  final SettlementInfo? settlement;

  // Structured dropoff — used by the Edit flow to pre-populate the form.
  final String? dropoffDistrict;
  final String? dropoffMandiName;
  final String? dropoffStallNumber;

  bool get hasRider => rider != null;
  bool get hasSettlement => settlement != null;

  bool get isPending => status == 'PENDING';
  bool get isCancelled => status == 'CANCELLED';
  bool get isCompleted => status == 'COMPLETED';

  /// Rider assigned but not yet picked up.
  bool get isAcceptedState => tripStatus == 'ACCEPTED';

  /// Picked up and en route — status was normalized to IN_TRANSIT.
  bool get isInTransitState =>
      tripStatus == 'PICKED_UP' ||
      (status == 'IN_TRANSIT' && tripStatus != 'ACCEPTED');

  /// Whether the farmer can still edit or cancel this order.
  bool get isEditable => isPending;

  /// Estimated transport cost (farmer pays the rider). Uses the same
  /// formula the backend applies at settlement time, with the default
  /// 10 km distance assumption — exact distance is unknown pre-acceptance.
  double get estimatedTransportCost {
    const baseFare = 50.0;
    const distanceKm = 10.0;
    const distanceRatePerKm = 15.0;
    const weightFreeKg = 50.0;
    const weightSurchargePerKg = 2.0;

    final distanceFare = distanceKm * distanceRatePerKm;
    final weightSurcharge =
        (crop.weightKg > weightFreeKg ? crop.weightKg - weightFreeKg : 0.0) *
            weightSurchargePerKg;
    return baseFare + distanceFare + weightSurcharge;
  }

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
  CropInfo({required this.cropName, required this.weightKg});

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

  String get displayStatus {
    final s = status.toUpperCase();
    if (s == 'PAID') return 'SETTLED';
    return s;
  }
}

// ============================================================================
// Screen
// ============================================================================

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

  /// Set true when either the edit flow or the cancel flow succeeded.
  /// Propagated to the orders list so it knows to refresh on return.
  bool _hasChanged = false;

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
  // Actions
  // -------------------------------------------------------------------------

  Future<void> _onEditRequest(OrderDetail order) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => Scaffold(
          backgroundColor: Colors.grey.shade50,
          appBar: AppBar(
            title: const Text('Edit Request'),
            backgroundColor: _kFarmerGreen,
            foregroundColor: Colors.white,
          ),
          body: FarmerBookTransportTab(
            editOrderId: order.id,
            initialCropType: order.crop.cropName,
            initialWeightKg: order.crop.weightKg,
            initialDropoffDistrict: order.dropoffDistrict,
            initialDropoffMandiName: order.dropoffMandiName,
            initialDropoffStallNumber: order.dropoffStallNumber,
            initialPickupAddress: order.pickup.address,
            initialPickupLandmark: order.pickup.landmark,
          ),
        ),
      ),
    );

    if (changed == true && mounted) {
      setState(() => _hasChanged = true);
      await _fetch();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Order updated successfully.'),
            backgroundColor: _kFarmerGreen,
          ),
        );
    }
  }

  Future<void> _onCancelOrder(OrderDetail order) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => _CancelReasonDialog(orderRef: order.id),
    );
    if (reason == null || !mounted) return;

    final auth = context.read<AuthProvider>();
    if (auth.token == null) return;

    setState(() => _isLoading = true);

    try {
      final response = await http.post(
        Uri.parse('$_kApiBaseUrl/farmer/orders/${order.id}/cancel'),
        headers: {
          ..._headers(auth),
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'cancellation_reason': reason}),
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text('Order cancelled.'),
              backgroundColor: _kFarmerGreen,
            ),
          );
        Navigator.of(context).pop(true);
        return;
      }

      setState(() => _isLoading = false);
      final message = _extractError(response) ??
          'Could not cancel order (HTTP ${response.statusCode}).';
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: Colors.red.shade700,
          ),
        );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('Network error: $e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
    }
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
        // Manual back handling so `_hasChanged` reaches the caller.
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(_hasChanged),
        ),
      ),
      body: _buildBody(),
      bottomNavigationBar: _buildStickyActions(),
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

          if (order.isCancelled) ...[
            _CancelledBanner(reason: order.cancellationReason),
            const SizedBox(height: 16),
          ],

          // SECTION: full order specs — always visible.
          _SpecCard(order: order),
          const SizedBox(height: 16),

          // SECTION: rider card (ACCEPTED only).
          if (order.isAcceptedState && order.hasRider) ...[
            _RiderSection(rider: order.rider!),
            const SizedBox(height: 16),
          ],

          // SECTION: pickup OTP banner (ACCEPTED only).
          if (order.isAcceptedState && order.pickupOtp != null) ...[
            _PickupOtpBanner(otp: order.pickupOtp!),
            const SizedBox(height: 16),
          ],

          // SECTION: progress timeline + payout (IN_TRANSIT/COMPLETED).
          if (order.isInTransitState || order.isCompleted) ...[
            _TimelineCard(order: order),
            const SizedBox(height: 16),
            _FinancialCard(settlement: order.settlement),
          ],
        ],
      ),
    );
  }

  /// Sticky bottom action bar. Only PENDING orders get actions.
  Widget? _buildStickyActions() {
    final order = _order;
    if (order == null || !order.isPending) return null;

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border(
            top: BorderSide(color: Colors.grey.shade200),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _onEditRequest(order),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _kFarmerGreen,
                  side: const BorderSide(color: _kFarmerGreen),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  textStyle: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('Edit Request'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: () => _onCancelOrder(order),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.red.shade600,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  textStyle: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                icon: const Icon(Icons.close, size: 18),
                label: const Text('Cancel Order'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// Header card
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
// Specs card — crop / weight / route / price estimate
// ============================================================================

class _SpecCard extends StatelessWidget {
  const _SpecCard({required this.order});

  final OrderDetail order;

  static String _rupees(double amount) {
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

    return _SectionCard(
      title: 'Order Specifications',
      icon: Icons.receipt_long_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DetailRow(label: 'Crop', value: order.crop.cropName),
          _DetailRow(
            label: 'Weight',
            value: '${order.crop.weightKg.toStringAsFixed(0)} kg',
          ),
          const SizedBox(height: 14),
          const _SubHeading(text: 'ROUTE'),
          const SizedBox(height: 6),
          _RouteRow(
            icon: Icons.location_on_outlined,
            label: 'Pickup',
            value: order.pickup.displayAddress,
            subline: order.pickup.hasLandmark
                ? order.pickup.landmark!.trim()
                : null,
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Icon(
              Icons.arrow_downward,
              size: 14,
              color: Color(0xFF6B7280),
            ),
          ),
          _RouteRow(
            icon: Icons.flag_outlined,
            label: 'Dropoff',
            value: order.dropoff.displayAddress,
          ),
          const SizedBox(height: 14),
          if (order.isPending) ...[
            const Divider(height: 1),
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(
                  Icons.currency_rupee,
                  size: 16,
                  color: _kFarmerGreen,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Estimated Transport Cost',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Text(
                  _rupees(order.estimatedTransportCost),
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: _kFarmerGreen,
                    fontSize: 15,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Estimated for a ~10 km trip. Final price is '
              'settled at delivery.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontSize: 11,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ============================================================================
// Rider section (ACCEPTED only)
// ============================================================================

class _RiderSection extends StatelessWidget {
  const _RiderSection({required this.rider});

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

    return _SectionCard(
      title: 'Assigned Rider',
      icon: Icons.delivery_dining,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DetailRow(label: 'Rider Name', value: rider.fullName),
          _DetailRow(
            label: 'Vehicle Plate',
            value: (rider.vehicleNumber ?? '').trim().isEmpty
                ? '—'
                : rider.vehicleNumber!.trim(),
          ),
          _DetailRow(
            label: 'Vehicle Type',
            value: (rider.vehicleType ?? '').trim().isEmpty
                ? '—'
                : rider.vehicleType!.trim(),
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
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  textStyle: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
                icon: const Icon(Icons.phone, size: 18),
                label: Text(
                  'CALL RIDER',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ============================================================================
// Pickup OTP banner (ACCEPTED only)
// ============================================================================

class _PickupOtpBanner extends StatelessWidget {
  const _PickupOtpBanner({required this.otp});

  final String otp;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7E0),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFFE0A3), width: 1.5),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.vpn_key_rounded,
            size: 24,
            color: Color(0xFF8A5A00),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Pickup OTP',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF8A5A00),
                    letterSpacing: 1.0,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  otp,
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF8A5A00),
                    letterSpacing: 8,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Share this code with the rider at pickup.',
                  style: TextStyle(
                    fontSize: 11,
                    color: Color(0xFF8A5A00),
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

// ============================================================================
// Timeline card (IN_TRANSIT / COMPLETED)
// ============================================================================

class _TimelineCard extends StatelessWidget {
  const _TimelineCard({required this.order});

  final OrderDetail order;

  static const List<String> _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  String _formatDateTime(DateTime d) {
    final local = d.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '${local.day} ${_months[local.month - 1]} ${local.year} · $hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    final trip = order.tripStatus;
    final completed = order.completedAt;

    final steps = <_TimelineStep>[
      _TimelineStep(
        label: 'Order Placed',
        timestamp: _formatDateTime(order.createdAt),
        done: true,
      ),
      _TimelineStep(
        label: 'Rider Assigned',
        timestamp: trip != null &&
                (trip == 'ACCEPTED' ||
                    trip == 'PICKED_UP' ||
                    trip == 'DELIVERED')
            ? ''
            : null,
        done: trip == 'ACCEPTED' ||
            trip == 'PICKED_UP' ||
            trip == 'DELIVERED',
      ),
      _TimelineStep(
        label: 'In Transit',
        timestamp: trip == 'PICKED_UP' || trip == 'DELIVERED' ? '' : null,
        done: trip == 'PICKED_UP' || trip == 'DELIVERED',
      ),
      _TimelineStep(
        label: 'Delivered',
        timestamp: completed != null ? _formatDateTime(completed) : null,
        done: trip == 'DELIVERED' || order.status == 'COMPLETED',
      ),
    ];

    return _SectionCard(
      title: 'Delivery Progress',
      icon: Icons.timeline_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (int i = 0; i < steps.length; i++)
            _TimelineRow(
              step: steps[i],
              isLast: i == steps.length - 1,
            ),
        ],
      ),
    );
  }
}

class _TimelineStep {
  _TimelineStep({
    required this.label,
    required this.done,
    this.timestamp,
  });

  final String label;
  final bool done;
  final String? timestamp;
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({required this.step, required this.isLast});

  final _TimelineStep step;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = step.done ? _kFarmerGreen : Colors.grey.shade400;

    return SizedBox(
      height: 56,
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
                    color: step.done ? _kFarmerGreen : Colors.white,
                    shape: BoxShape.circle,
                    border: Border.all(color: color, width: 2),
                  ),
                  child: step.done
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
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    step.label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight:
                          step.done ? FontWeight.w600 : FontWeight.normal,
                      color: step.done ? Colors.black87 : Colors.black54,
                    ),
                  ),
                  if (step.timestamp != null && step.timestamp!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        step.timestamp!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontSize: 11.5,
                        ),
                      ),
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

// ============================================================================
// Financial breakdown
// ============================================================================

class _FinancialCard extends StatelessWidget {
  const _FinancialCard({required this.settlement});

  final SettlementInfo? settlement;

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
        title: 'Payout Breakdown',
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
                  'Settlement will be created once the delivery is completed.',
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
      title: 'Payout Breakdown',
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
// Cancelled banner
// ============================================================================

class _CancelledBanner extends StatelessWidget {
  const _CancelledBanner({this.reason});

  final String? reason;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.red.shade200),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.cancel_outlined,
              size: 20, color: Colors.red.shade700),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'This order was cancelled.',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: Colors.red.shade800,
                  ),
                ),
                if (reason != null && reason!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Reason: $reason',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.red.shade700,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// Cancel reason dialog
// ============================================================================

class _CancelReasonDialog extends StatefulWidget {
  const _CancelReasonDialog({required this.orderRef});

  final String orderRef;

  @override
  State<_CancelReasonDialog> createState() => _CancelReasonDialogState();
}

class _CancelReasonDialogState extends State<_CancelReasonDialog> {
  static const List<String> _reasons = [
    'Changed my mind',
    'Found alternative transport',
    'Crop not ready for pickup',
    'Price too high',
    'Booking mistake',
    'Other',
  ];

  String _selected = _reasons.first;

  String get _shortRef {
    final compact = widget.orderRef.replaceAll('-', '');
    final take = compact.length >= 6 ? compact.substring(0, 6) : compact;
    return '#KR-${take.toUpperCase()}';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Cancel Order $_shortRef?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Please tell us why you are cancelling this order:',
            style: TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 12),
          ..._reasons.map(
            (r) => RadioListTile<String>(
              value: r,
              groupValue: _selected,
              onChanged: (v) => setState(() => _selected = v ?? _selected),
              title: Text(r, style: const TextStyle(fontSize: 13.5)),
              contentPadding: EdgeInsets.zero,
              dense: true,
              activeColor: _kFarmerGreen,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Keep Order'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_selected),
          style: FilledButton.styleFrom(
            backgroundColor: Colors.red.shade600,
          ),
          child: const Text('Cancel Order'),
        ),
      ],
    );
  }
}

// ============================================================================
// Shared primitives
// ============================================================================

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

class _RouteRow extends StatelessWidget {
  const _RouteRow({
    required this.icon,
    required this.label,
    required this.value,
    this.subline,
  });

  final IconData icon;
  final String label;
  final String value;
  final String? subline;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: _kFarmerGreen),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                  fontSize: 11,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (subline != null && subline!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    subline!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
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

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final String status;

  static const Map<String, (Color, Color)> _colors = {
    'COMPLETED': (Color(0xFF166534), Color(0x2616A34A)),
    'CANCELLED': (Color(0xFF991B1B), Color(0x26DC2626)),
    'IN_TRANSIT': (Color(0xFF6D28D9), Color(0x266D28D9)),
    'PENDING': (Color(0xFFB45309), Color(0x26F59E0B)),
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