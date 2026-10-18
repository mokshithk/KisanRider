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

/// Brand green used across the rider UI.
const Color _kRiderGreen = Color(0xFF2E7D32);

// ============================================================================
// Models
// ============================================================================

class RiderTripDetail {
  RiderTripDetail({
    required this.id,
    required this.status,
    required this.pickup,
    required this.mandi,
    required this.crop,
    this.completedAt,
    this.distanceKm,
    this.farmer,
    this.fare,
  });

  factory RiderTripDetail.fromJson(Map<String, dynamic> json) {
    return RiderTripDetail(
      id: (json['id'] ?? '').toString(),
      status: (json['status'] ?? 'DELIVERED').toString(),
      completedAt: _parseDate(json['completed_at']),
      distanceKm: (json['distance_km'] as num?)?.toDouble(),
      farmer: json['farmer'] is Map<String, dynamic>
          ? RiderTripFarmerInfo.fromJson(
              json['farmer'] as Map<String, dynamic>)
          : null,
      pickup: RiderTripLocationInfo.fromJson(
          (json['pickup'] as Map<String, dynamic>?) ?? const {}),
      mandi: RiderTripMandiInfo.fromJson(
          (json['mandi'] as Map<String, dynamic>?) ?? const {}),
      crop: RiderTripCropInfo.fromJson(
          (json['crop'] as Map<String, dynamic>?) ?? const {}),
      fare: json['fare'] is Map<String, dynamic>
          ? RiderTripFareBreakdown.fromJson(
              json['fare'] as Map<String, dynamic>)
          : null,
    );
  }

  final String id;

  /// "DELIVERED" or "CANCELLED".
  final String status;

  final DateTime? completedAt;
  final double? distanceKm;

  final RiderTripFarmerInfo? farmer;
  final RiderTripLocationInfo pickup;
  final RiderTripMandiInfo mandi;
  final RiderTripCropInfo crop;

  /// None for cancelled trips (or if the settlement row is missing for
  /// some reason).
  final RiderTripFareBreakdown? fare;

  bool get hasFarmer => farmer != null;
  bool get hasFare => fare != null;
  bool get isCancelled => status.toUpperCase() == 'CANCELLED';

  static DateTime? _parseDate(dynamic raw) {
    if (raw == null) return null;
    if (raw is String) return DateTime.tryParse(raw);
    return null;
  }
}

class RiderTripFarmerInfo {
  RiderTripFarmerInfo({
    required this.id,
    required this.fullName,
    this.phoneNumber,
    this.farmAddress,
  });

  factory RiderTripFarmerInfo.fromJson(Map<String, dynamic> json) {
    return RiderTripFarmerInfo(
      id: (json['id'] ?? '').toString(),
      fullName: (json['full_name'] ?? '—').toString(),
      phoneNumber: json['phone_number']?.toString(),
      farmAddress: json['farm_address']?.toString(),
    );
  }

  final String id;
  final String fullName;
  final String? phoneNumber;
  final String? farmAddress;

  bool get hasPhone =>
      phoneNumber != null && phoneNumber!.trim().isNotEmpty;

  bool get hasAddress =>
      farmAddress != null && farmAddress!.trim().isNotEmpty;
}

class RiderTripLocationInfo {
  RiderTripLocationInfo({
    this.address,
    this.landmark,
    this.latitude,
    this.longitude,
  });

  factory RiderTripLocationInfo.fromJson(Map<String, dynamic> json) {
    return RiderTripLocationInfo(
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

class RiderTripMandiInfo {
  RiderTripMandiInfo({
    this.mandiName,
    this.traderName,
    this.stallNumber,
  });

  factory RiderTripMandiInfo.fromJson(Map<String, dynamic> json) {
    return RiderTripMandiInfo(
      mandiName: json['mandi_name']?.toString(),
      traderName: json['trader_name']?.toString(),
      stallNumber: json['stall_number']?.toString(),
    );
  }

  final String? mandiName;
  final String? traderName;
  final String? stallNumber;

  bool get hasMandi =>
      mandiName != null && mandiName!.trim().isNotEmpty;
  bool get hasTrader =>
      traderName != null && traderName!.trim().isNotEmpty;
  bool get hasStall =>
      stallNumber != null && stallNumber!.trim().isNotEmpty;
}

class RiderTripCropInfo {
  RiderTripCropInfo({
    required this.cropName,
    required this.weightKg,
  });

  factory RiderTripCropInfo.fromJson(Map<String, dynamic> json) {
    return RiderTripCropInfo(
      cropName: (json['crop_name'] ?? '—').toString(),
      weightKg: ((json['weight_kg'] ?? 0) as num).toDouble(),
    );
  }

  final String cropName;
  final double weightKg;
}

class RiderTripFareBreakdown {
  RiderTripFareBreakdown({
    required this.grossTransportFare,
    required this.platformCommission,
    required this.netEarnings,
    required this.paymentMethod,
  });

  factory RiderTripFareBreakdown.fromJson(Map<String, dynamic> json) {
    return RiderTripFareBreakdown(
      grossTransportFare:
          ((json['gross_transport_fare'] ?? 0) as num).toDouble(),
      platformCommission:
          ((json['platform_commission'] ?? 0) as num).toDouble(),
      netEarnings: ((json['net_earnings'] ?? 0) as num).toDouble(),
      paymentMethod: (json['payment_method'] ?? '—').toString(),
    );
  }

  final double grossTransportFare;
  final double platformCommission;
  final double netEarnings;

  /// "QR Payment at Mandi" (settlement PAID) or "Cash in Hand"
  /// (settlement PENDING).
  final String paymentMethod;
}

// ============================================================================
// Screen
// ============================================================================

/// Full-detail view for a single trip. Fetches
/// `GET /rider/trips/{trip_id}` on mount and on pull-to-refresh, then
/// renders five sections top-to-bottom:
///
///   1. Completion Header — delivery timestamp + total distance.
///   2. Farmer Info — name, phone (with call button), farm address.
///   3. Mandi Unloading Info — APMC, trader, stall number.
///   4. Crop Load — crop and weight.
///   5. Fare & Earnings — gross, platform commission, net, payment mode.
class RiderTripDetailScreen extends StatefulWidget {
  const RiderTripDetailScreen({super.key, required this.tripId});

  final String tripId;

  @override
  State<RiderTripDetailScreen> createState() => _RiderTripDetailScreenState();
}

class _RiderTripDetailScreenState extends State<RiderTripDetailScreen> {
  RiderTripDetail? _trip;
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
        Uri.parse('$_kApiBaseUrl/rider/trips/${widget.tripId}'),
        headers: _headers(auth),
      );
      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() {
          _trip = RiderTripDetail.fromJson(data);
          _isLoading = false;
        });
      } else if (response.statusCode == 404) {
        setState(() {
          _error = 'Trip not found.';
          _isLoading = false;
        });
      } else {
        setState(() {
          _error = _extractError(response) ??
              'Failed to load trip (HTTP ${response.statusCode}).';
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
        title: const Text('Trip Details'),
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

    if (_error != null || _trip == null) {
      return _ErrorView(
        message: _error ?? 'Could not load trip.',
        onRetry: _fetch,
      );
    }

    final trip = _trip!;
    return RefreshIndicator(
      onRefresh: _fetch,
      color: _kRiderGreen,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          _CompletionHeaderCard(trip: trip),
          const SizedBox(height: 16),
          if (trip.hasFarmer) ...[
            _FarmerCard(farmer: trip.farmer!),
            const SizedBox(height: 16),
          ],
          _MandiCard(mandi: trip.mandi),
          const SizedBox(height: 16),
          _CropCard(crop: trip.crop),
          const SizedBox(height: 16),
          _FareCard(fare: trip.fare, isCancelled: trip.isCancelled),
        ],
      ),
    );
  }
}

// ============================================================================
// Section 1 — Completion header (timestamp + distance)
// ============================================================================

class _CompletionHeaderCard extends StatelessWidget {
  const _CompletionHeaderCard({required this.trip});

  final RiderTripDetail trip;

  static const List<String> _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  /// "12 Oct 2026 · 14:32" — with the time included, because on the
  /// detail screen the exact completion moment matters.
  String _formatDateTime(DateTime d) {
    final local = d.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '${local.day} ${_months[local.month - 1]} ${local.year} · '
        '$hh:$mm';
  }

  String get _shortRef {
    final compact = trip.id.replaceAll('-', '');
    final take = compact.length >= 6 ? compact.substring(0, 6) : compact;
    return '#TRIP-${take.toUpperCase()}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final completed = trip.completedAt;

    // Header copy: for cancelled trips we don't claim a delivery
    // timestamp — the trip ended, but the framing is different.
    final headerLabel = trip.isCancelled
        ? 'Trip Cancelled'
        : 'Trip Completed';

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _kRiderGreen.withOpacity(0.12),
            _kRiderGreen.withOpacity(0.03),
          ],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _kRiderGreen.withOpacity(0.30)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                trip.isCancelled
                    ? Icons.cancel_outlined
                    : Icons.check_circle_outline,
                color: trip.isCancelled
                    ? Colors.red.shade700
                    : _kRiderGreen,
                size: 22,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  headerLabel,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: trip.isCancelled
                        ? Colors.red.shade800
                        : _kRiderGreen,
                  ),
                ),
              ),
              _StatusBadge(status: trip.status),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Trip $_shortRef',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 14),

          // Two stat tiles: timestamp and distance.
          Row(
            children: [
              Expanded(
                child: _HeaderStat(
                  icon: Icons.schedule_outlined,
                  label: trip.isCancelled ? 'Ended on' : 'Delivered on',
                  value: completed == null ? '—' : _formatDateTime(completed),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _HeaderStat(
                  icon: Icons.route_outlined,
                  label: 'Distance',
                  value: trip.distanceKm == null
                      ? '—'
                      : '${trip.distanceKm!.toStringAsFixed(1)} km',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeaderStat extends StatelessWidget {
  const _HeaderStat({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// Section 2 — Farmer info
// ============================================================================

class _FarmerCard extends StatelessWidget {
  const _FarmerCard({required this.farmer});

  final RiderTripFarmerInfo farmer;

  Future<void> _call(BuildContext context) async {
    final cleaned = farmer.phoneNumber?.replaceAll(RegExp(r'[^\d+]'), '');
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
    return _SectionCard(
      title: 'Farmer Info',
      icon: Icons.agriculture_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DetailRow(label: 'Farmer', value: farmer.fullName),
          _DetailRow(
            label: 'Phone',
            value: farmer.hasPhone ? '+91 ${farmer.phoneNumber}' : '—',
          ),
          _DetailRow(
            label: 'Farm Address',
            value: farmer.hasAddress ? farmer.farmAddress!.trim() : '—',
          ),
          if (farmer.hasPhone) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => _call(context),
                style: FilledButton.styleFrom(
                  backgroundColor: _kRiderGreen,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  textStyle: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
                icon: const Icon(Icons.phone, size: 18),
                label: const Text('CALL FARMER'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ============================================================================
// Section 3 — Mandi unloading info
// ============================================================================

class _MandiCard extends StatelessWidget {
  const _MandiCard({required this.mandi});

  final RiderTripMandiInfo mandi;

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      title: 'Mandi Unloading',
      icon: Icons.storefront_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DetailRow(
            label: 'APMC Mandi',
            value: mandi.hasMandi ? mandi.mandiName!.trim() : '—',
          ),
          _DetailRow(
            label: 'Trader Name',
            value: mandi.hasTrader ? mandi.traderName!.trim() : '—',
          ),
          _DetailRow(
            label: 'Stall Number',
            value: mandi.hasStall ? mandi.stallNumber!.trim() : '—',
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// Section 4 — Crop load
// ============================================================================

class _CropCard extends StatelessWidget {
  const _CropCard({required this.crop});

  final RiderTripCropInfo crop;

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      title: 'Crop Load',
      icon: Icons.eco_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DetailRow(label: 'Crop', value: crop.cropName),
          _DetailRow(
            label: 'Total Weight',
            value: '${crop.weightKg.toStringAsFixed(0)} kg',
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// Section 5 — Fare & earnings breakdown
// ============================================================================

class _FareCard extends StatelessWidget {
  const _FareCard({required this.fare, required this.isCancelled});

  final RiderTripFareBreakdown? fare;
  final bool isCancelled;

  /// Indian-style digit grouping: 12,34,567 not 1,234,567.
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

    // Cancelled trips never had a payout.
    if (isCancelled || fare == null) {
      return _SectionCard(
        title: 'Fare & Earnings',
        icon: Icons.account_balance_wallet_outlined,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Icon(Icons.info_outline,
                  size: 16, color: Colors.grey.shade700),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isCancelled
                      ? 'No fare was earned on this trip — it was '
                          'cancelled before delivery.'
                      : 'Fare breakdown is not available for this trip.',
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

    final f = fare!;

    return _SectionCard(
      title: 'Fare & Earnings',
      icon: Icons.account_balance_wallet_outlined,
      trailing: _PaymentModeTag(mode: f.paymentMethod),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DetailRow(
            label: 'Gross Transport Fare',
            value: '+${_rupees(f.grossTransportFare)}',
            valueColor: Colors.black87,
            bold: true,
          ),
          _DetailRow(
            label: 'Platform Commission',
            value: '- ${_rupees(f.platformCommission)}',
            valueColor: Colors.red.shade700,
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Divider(height: 1),
          ),
          _DetailRow(
            label: 'Net Earnings',
            value: _rupees(f.netEarnings),
            valueColor: _kRiderGreen,
            bold: true,
          ),
        ],
      ),
    );
  }
}

/// Small pill showing whether the rider was paid at the mandi (QR) or
/// collected cash. Same underlying fact as the summary card's tag, just
/// worded for the detail context.
class _PaymentModeTag extends StatelessWidget {
  const _PaymentModeTag({required this.mode});

  final String mode;

  @override
  Widget build(BuildContext context) {
    final normalized = mode.toUpperCase();

    final Color fg;
    final Color bg;
    final IconData icon;

    switch (normalized) {
      case 'QR PAYMENT AT MANDI':
        fg = _kRiderGreen;
        bg = _kRiderGreen.withOpacity(0.12);
        icon = Icons.qr_code_2_outlined;
        break;
      case 'CASH IN HAND':
        fg = Colors.orange.shade900;
        bg = Colors.orange.withOpacity(0.15);
        icon = Icons.payments_outlined;
        break;
      default:
        fg = Colors.black54;
        bg = Colors.black12;
        icon = Icons.help_outline;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: fg),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: fg),
          const SizedBox(width: 4),
          Text(
            mode,
            style: TextStyle(
              color: fg,
              fontWeight: FontWeight.bold,
              fontSize: 10,
              letterSpacing: 0.4,
            ),
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
                Icon(icon, size: 18, color: _kRiderGreen),
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
            width: 140,
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

/// Status pill for the trip's terminal state — DELIVERED (green) or
/// CANCELLED (red). Unknown values fall back to grey.
class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final String status;

  static const Map<String, (Color, Color)> _colors = {
    'DELIVERED': (Color(0xFF166534), Color(0x2616A34A)),
    'CANCELLED': (Color(0xFF991B1B), Color(0x26DC2626)),
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
              'Could not load trip',
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