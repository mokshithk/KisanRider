import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_strings.dart';
import '../providers/auth_provider.dart';
import '../services/api_service.dart';
import 'farmer_dashboard.dart';

/// Base URL of the FastAPI backend.
String get _kApiBaseUrl => ApiService.baseUrl;

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
    this.requestedPickupAt,
    this.pickupWindowStart,
    this.pickupWindowEnd,
    this.riderExpectedPickupAt,
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
      requestedPickupAt: _parseDate(json['requested_pickup_at']),
      pickupWindowStart: _parseDate(json['pickup_window_start']),
      pickupWindowEnd: _parseDate(json['pickup_window_end']),
      riderExpectedPickupAt: _parseDate(json['rider_expected_pickup_at']),
    );
  }

  final String id;
  final String status;
  final String? tripStatus;
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

  final String? dropoffDistrict;
  final String? dropoffMandiName;
  final String? dropoffStallNumber;
  final DateTime? requestedPickupAt;
  final DateTime? pickupWindowStart;
  final DateTime? pickupWindowEnd;
  final DateTime? riderExpectedPickupAt;

  bool get hasRider => rider != null;
  bool get hasSettlement => settlement != null;

  bool get isPending => status == 'PENDING';
  bool get isCancelled => status == 'CANCELLED';
  bool get isCompleted => status == 'COMPLETED';
  bool get isExpired => status == 'EXPIRED';
  bool get isAcceptedState =>
      tripStatus == 'ACCEPTED' ||
      (status == 'ACCEPTED' && tripStatus == null);
  bool get isInTransitState =>
      tripStatus == 'PICKED_UP' ||
      (status == 'IN_TRANSIT' && tripStatus != 'ACCEPTED');

  bool get isEditable => isPending;

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
    this.id,
    this.grossAmount,
    this.riderFare,
    this.platformFee,
    this.netPayout,
    this.ratePerKg,
    this.rateSource,
    this.paymentReference,
    this.paymentMethod,
    this.paidAt,
    this.createdAt,
  });

  factory SettlementInfo.fromJson(Map<String, dynamic> json) {
    return SettlementInfo(
      id: json['id']?.toString(),
      status: (json['status'] ?? 'PENDING').toString(),
      grossAmount: (json['gross_amount'] as num?)?.toDouble(),
      riderFare: (json['rider_fare'] as num?)?.toDouble(),
      platformFee: (json['platform_fee'] as num?)?.toDouble(),
      netPayout: (json['net_payout'] as num?)?.toDouble(),
      ratePerKg: (json['rate_per_kg'] as num?)?.toDouble(),
      rateSource: json['rate_source']?.toString(),
      paymentReference: json['payment_reference']?.toString(),
      paymentMethod: json['payment_method']?.toString(),
      paidAt: json['paid_at'] is String
          ? DateTime.tryParse(json['paid_at'] as String)
          : null,
      createdAt: json['created_at'] is String
          ? DateTime.tryParse(json['created_at'] as String)
          : null,
    );
  }

  final String? id;
  final String status;
  final double? grossAmount;
  final double? riderFare;
  final double? platformFee;
  final double? netPayout;
  final double? ratePerKg;
  final String? rateSource;
  final String? paymentReference;
  final String? paymentMethod;
  final DateTime? paidAt;
  final DateTime? createdAt;

  bool get isPaid => status.toUpperCase() == 'PAID';

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
  bool _hasChanged = false;
  Timer? _paymentPollTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _fetch());
  }

  @override
  void dispose() {
    _paymentPollTimer?.cancel();
    super.dispose();
  }

  void _syncPaymentPolling(OrderDetail? order) {
    final needsPoll = order != null &&
        order.isCompleted &&
        order.settlement != null &&
        !order.settlement!.isPaid;
    if (needsPoll && (_paymentPollTimer == null || !_paymentPollTimer!.isActive)) {
      _paymentPollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        _fetch(silent: true);
      });
    } else if (!needsPoll && _paymentPollTimer != null) {
      _paymentPollTimer!.cancel();
      _paymentPollTimer = null;
    }
  }

  Map<String, String> _headers(AuthProvider auth) => {
        'Authorization': 'Bearer ${auth.token}',
        'Accept': 'application/json',
      };

  Future<void> _fetch({bool silent = false}) async {
    final auth = context.read<AuthProvider>();
    if (auth.token == null) {
      if (!silent) {
        setState(() {
          _isLoading = false;
          _error = AppStrings.tr('Not signed in.');
        });
      }
      return;
    }

    if (!silent) {
      setState(() {
        _isLoading = true;
        _error = null;
      });
    }

    try {
      final response = await http.get(
        Uri.parse('$_kApiBaseUrl/farmer/orders/${widget.orderId}'),
        headers: _headers(auth),
      );
      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final loaded = OrderDetail.fromJson(data);
        setState(() {
          _order = loaded;
          _isLoading = false;
        });
        _syncPaymentPolling(loaded);
      } else if (!silent && response.statusCode == 404) {
        setState(() {
          _error = AppStrings.tr('Order not found.');
          _isLoading = false;
        });
      } else if (!silent) {
        setState(() {
          _error = _extractError(response) ??
              AppStrings.tr(
                'Failed to load order (HTTP {code}).',
                args: {'code': '${response.statusCode}'},
              );
          _isLoading = false;
        });
      }
    } catch (e) {
      if (!mounted || silent) return;
      setState(() {
        _error = AppStrings.tr(
          'Network error: {err}',
          args: {'err': '$e'},
        );
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
    } catch (_) {
      // Fallback if body is not JSON
      return AppStrings.tr(
        'Server error (HTTP {code}). Check backend logs.',
        args: {'code': '${response.statusCode}'},
      );
    }
    return null;
  }

  Future<void> _onEditRequest(OrderDetail order) async {
    // Navigate to the Book Transport screen in EDIT mode
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (ctx) => Scaffold(
          backgroundColor: Colors.grey.shade50,
          appBar: AppBar(
            title: Text(ctx.tr('Edit Request')),
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
          SnackBar(
            content: Text(context.trAsync('Order updated successfully.')),
            backgroundColor: _kFarmerGreen,
          ),
        );
    }
  }

  /// Cancel flow.
  ///
  /// Sends `POST /farmer/orders/{id}/cancel` with the chosen reason. The
  /// backend now guarantees the whole mutation is wrapped in a
  /// `try/except SQLAlchemyError` with rollback, and reports any raw SQL
  /// failure as a fixed `500 {"detail": "Failed to cancel order"}` rather
  /// than leaking a driver message.
  ///
  /// On the client we therefore:
  ///   * Only treat HTTP 200 as success — show a fixed green
  ///     "Order cancelled successfully" toast and `pop(true)` so the
  ///     list screen refreshes.
  ///   * On any non-200 (400/500/…), show a fixed, user-friendly
  ///     "Could not cancel order. Please try again." toast. We do NOT
  ///     surface `response.body` — the raw body may contain a stack
  ///     trace, SQL fragment, or other internal detail we never want
  ///     rendered in the UI.
  ///   * On a network exception, show the same fixed message so the
  ///     user sees a single, clear failure mode.
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
            SnackBar(
              content: Text(context.trAsync('Order cancelled successfully')),
              backgroundColor: _kFarmerGreen,
            ),
          );
        // Pop back to the orders list. The caller (`FarmerOrdersTab`)
        // treats a `true` result as "something changed — please refetch"
        // and will refresh its list automatically.
        Navigator.of(context).pop(true);
        return;
      }

      // Non-200: fixed, user-facing message. Raw response body is
      // intentionally discarded — it may contain internal details.
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              context.trAsync('Could not cancel order. Please try again.'),
            ),
            backgroundColor: Colors.red.shade700,
          ),
        );
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              context.trAsync('Could not cancel order. Please try again.'),
            ),
            backgroundColor: Colors.red.shade700,
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade50,
      appBar: AppBar(
        title: Text(context.tr('Order Details')),
        backgroundColor: _kFarmerGreen,
        foregroundColor: Colors.white,
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
        message: _error ?? context.tr('Could not load order.'),
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

          _SpecCard(order: order),
          const SizedBox(height: 16),

          if (order.isAcceptedState && order.hasRider) ...[
            _RiderSection(rider: order.rider!),
            const SizedBox(height: 16),
          ],

          if (order.isAcceptedState && order.pickupOtp != null) ...[
            _PickupOtpBanner(otp: order.pickupOtp!),
            const SizedBox(height: 16),
          ],

          if (order.isInTransitState || order.isCompleted) ...[
            _TimelineCard(order: order),
            const SizedBox(height: 16),
            _FinancialCard(settlement: order.settlement),
          ],
        ],
      ),
    );
  }

  Widget? _buildStickyActions() {
    final order = _order;
    if (order == null || !order.isPending) return null;

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Colors.grey.shade200)),
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
                label: Text(context.tr('Edit Request')),
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
                label: Text(context.tr('Cancel Order')),
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

  String _formatDate(DateTime d) {
    final local = d.toLocal();
    return '${local.day} ${AppStrings.trShortMonth(local.month)} ${local.year}';
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
                  context.tr('Order {ref}', args: {'ref': _shortRef}),
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
            context.tr(
              'Placed on {date}',
              args: {'date': _formatDate(order.createdAt)},
            ),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (order.completedAt != null) ...[
            const SizedBox(height: 2),
            Text(
              context.tr(
                'Completed on {date}',
                args: {'date': _formatDate(order.completedAt!)},
              ),
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
// Specs card
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
      title: context.tr('Order Specifications'),
      icon: Icons.receipt_long_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DetailRow(label: context.tr('Crop'), value: order.crop.cropName),
          _DetailRow(
            label: context.tr('Weight'),
            value: '${order.crop.weightKg.toStringAsFixed(0)} ${context.tr('kg')}',
          ),
          if (order.pickupWindowStart != null && order.pickupWindowEnd != null) ...[
            _DetailRow(
              label: context.tr('Pickup Window'),
              value: '${order.pickupWindowStart!.toLocal().day}/${order.pickupWindowStart!.toLocal().month} ${order.pickupWindowStart!.toLocal().hour.toString().padLeft(2, '0')}:${order.pickupWindowStart!.toLocal().minute.toString().padLeft(2, '0')} — ${order.pickupWindowEnd!.toLocal().day}/${order.pickupWindowEnd!.toLocal().month} ${order.pickupWindowEnd!.toLocal().hour.toString().padLeft(2, '0')}:${order.pickupWindowEnd!.toLocal().minute.toString().padLeft(2, '0')}',
            ),
          ] else if (order.requestedPickupAt != null) ...[
            _DetailRow(
              label: context.tr('Pickup Requested'),
              value: '${order.requestedPickupAt!.toLocal().day}/${order.requestedPickupAt!.toLocal().month} ${context.tr('at')} ${order.requestedPickupAt!.toLocal().hour.toString().padLeft(2, '0')}:${order.requestedPickupAt!.toLocal().minute.toString().padLeft(2, '0')}',
            ),
          ],
          if (order.riderExpectedPickupAt != null) ...[
            _DetailRow(
              label: context.tr('Rider Expected Pickup'),
              value: '${order.riderExpectedPickupAt!.toLocal().day}/${order.riderExpectedPickupAt!.toLocal().month} ${context.tr('at')} ${order.riderExpectedPickupAt!.toLocal().hour.toString().padLeft(2, '0')}:${order.riderExpectedPickupAt!.toLocal().minute.toString().padLeft(2, '0')}',
            ),
          ],
          const SizedBox(height: 14),
          _SubHeading(text: context.tr('ROUTE')),
          const SizedBox(height: 6),
          _RouteRow(
            icon: Icons.location_on_outlined,
            label: context.tr('Pickup'),
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
            label: context.tr('Dropoff'),
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
                    context.tr('Estimated Transport Cost'),
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
              context.tr(
                'Estimated for a ~10 km trip. Final price is settled at delivery.',
              ),
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
// Rider section
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
          SnackBar(
            content: Text(
              context.trAsync(
                'Could not open dialer for {phone}',
                args: {'phone': cleaned},
              ),
            ),
          ),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.trAsync('Could not open the phone dialer'),
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return _SectionCard(
      title: context.tr('Assigned Rider'),
      icon: Icons.delivery_dining,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DetailRow(label: context.tr('Rider Name'), value: rider.fullName),
          _DetailRow(
            label: context.tr('Vehicle Plate'),
            value: (rider.vehicleNumber ?? '').trim().isEmpty
                ? '—'
                : rider.vehicleNumber!.trim(),
          ),
          _DetailRow(
            label: context.tr('Vehicle Type'),
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
                  context.tr('CALL RIDER'),
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
// Pickup OTP banner
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
                Text(
                  context.tr('Pickup OTP'),
                  style: const TextStyle(
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
                Text(
                  context.tr('Share this code with the rider at pickup.'),
                  style: const TextStyle(
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
// Timeline card
// ============================================================================

class _TimelineCard extends StatelessWidget {
  const _TimelineCard({required this.order});

  final OrderDetail order;

  String _formatDateTime(DateTime d) {
    final local = d.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '${local.day} ${AppStrings.trShortMonth(local.month)} ${local.year} · $hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    final trip = order.tripStatus;
    final completed = order.completedAt;

    final steps = <_TimelineStep>[
      _TimelineStep(
        label: context.tr('Order Placed'),
        timestamp: _formatDateTime(order.createdAt),
        done: true,
      ),
      _TimelineStep(
        label: context.tr('Rider Assigned'),
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
        label: context.tr('In Transit'),
        timestamp: trip == 'PICKED_UP' || trip == 'DELIVERED' ? '' : null,
        done: trip == 'PICKED_UP' || trip == 'DELIVERED',
      ),
      _TimelineStep(
        label: context.tr('Delivered'),
        timestamp: completed != null ? _formatDateTime(completed) : null,
        done: trip == 'DELIVERED' || order.status == 'COMPLETED',
      ),
    ];

    return _SectionCard(
      title: context.tr('Delivery Progress'),
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
        title: context.tr('Payout Breakdown'),
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
                  context.tr(
                    'Settlement will be created once the delivery is completed.',
                  ),
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
      title: context.tr('Payout Breakdown'),
      icon: Icons.account_balance_wallet_outlined,
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          color: statusBg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: statusColor),
        ),
        child: Text(
          context.trStatus(s.displayStatus),
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
            label: context.tr('Gross Sale Amount'),
            value: s.grossAmount == null
                ? context.tr('Pending Calculation')
                : _rupees(s.grossAmount),
          ),
          _DetailRow(
            label: context.tr('Transport Fee'),
            value: s.riderFare == null
                ? '—'
                : '- ${_rupees(s.riderFare)}',
            valueColor: Colors.red.shade700,
          ),
          _DetailRow(
            label: context.tr('Platform Fee'),
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
            label: context.tr('Net Payout'),
            value: _rupees(s.netPayout),
            valueColor: _kFarmerGreen,
            bold: true,
          ),
          if (s.ratePerKg != null) ...[
            const SizedBox(height: 6),
            _DetailRow(
              label: context.tr('Crop Rate Applied'),
              value:
                  '₹${s.ratePerKg!.toStringAsFixed(0)}/${context.tr('kg')} (${s.rateSource == 'mandi_api' ? context.tr('Mandi API Rate') : context.tr('Standard ₹50/kg')})',
            ),
          ],
          if (s.isPaid) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFE8F5E9),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFA5D6A7)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.verified, size: 18, color: _kFarmerGreen),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      s.paymentReference != null
                          ? context.tr(
                              'Payment Received via Mandi QR ({ref})',
                              args: {'ref': s.paymentReference!},
                            )
                          : context.tr('Payment Received & Settled'),
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF166534),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
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
                  context.tr('This order was cancelled.'),
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: Colors.red.shade800,
                  ),
                ),
                if (reason != null && reason!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    context.tr('Reason: {reason}', args: {'reason': reason!}),
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
      title: Text(
        context.tr('Cancel Order {ref}?', args: {'ref': _shortRef}),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.tr('Please tell us why you are cancelling this order:'),
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 12),
          ..._reasons.map(
            (r) => RadioListTile<String>(
              value: r,
              groupValue: _selected,
              onChanged: (v) => setState(() => _selected = v ?? _selected),
              title: Text(context.tr(r), style: const TextStyle(fontSize: 13.5)),
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
          child: Text(context.tr('Keep Order')),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_selected),
          style: FilledButton.styleFrom(
            backgroundColor: Colors.red.shade600,
          ),
          child: Text(context.tr('Cancel Order')),
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
        context.trStatus(normalized.replaceAll('_', ' ')),
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
              context.tr('Could not load order'),
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
              label: Text(context.tr('Retry')),
            ),
          ],
        ),
      ),
    );
  }
}