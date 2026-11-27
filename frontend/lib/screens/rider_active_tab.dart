import 'pools/rider_pool_detail_screen.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../providers/auth_provider.dart';
import '../widgets/segmented_filter_bar.dart';
import 'payment_qr_dialog.dart';
import 'rider_common.dart';

/// Statuses from which a rider may complete a delivery.
const Set<String> _kCompletableTripStatuses = {'PICKED_UP', 'IN_TRANSIT'};

/// Upload + status-PATCH timeout.
const Duration _kUploadTimeout = kDeliveryUploadTimeout;

// ============================================================================
// Model — mirrors the compact list shape returned by
// GET /rider/trips/active.
// ============================================================================

/// One row from `GET /rider/trips/active`.
///
/// The endpoint returns everything the card *and* the operational detail
/// sheet need in one call — so opening a trip sheet is instant (no second
/// round-trip) and the list stays cheap to refresh.
///
/// ## Status normalization
///
/// The backend normalizes statuses to a small, closed set the client can
/// filter on:
///
///   ACCEPTED   — rider is en route to the pickup farm
///   PICKED_UP  — rider has verified the OTP and is en route to mandi
///                (backend collapses both `PICKED_UP` and `IN_TRANSIT`
///                into this one client-facing value)
///   COMPLETED  — trip is delivered; receipt view only
///
/// The original backend status is preserved on [rawStatus] for callers
/// that need to distinguish `IN_TRANSIT` from `PICKED_UP` for logging.
class RiderActiveTrip {
  RiderActiveTrip({
    required this.id,
    required this.produceRequestId,
    required this.status,
    required this.rawStatus,
    required this.cropName,
    required this.weightKg,
    this.dropoffMandi,
    this.dropoffStall,
    this.dropoffAddress,
    this.pickupAddress,
    this.pickupLandmark,
    this.pickupLatitude,
    this.pickupLongitude,
    this.farmerFullName,
    this.farmerPhoneNumber,
    this.farmAddress,
    this.createdAt,
    this.completedAt,
    this.poolId,
    this.riderExpectedPickupAt,
    this.pickupWindowStart,
    this.pickupWindowEnd,
    this.settlementId,
    this.paymentStatus,
    this.grossAmount,
    this.riderFare,
    this.platformFee,
    this.netPayout,
    this.ratePerKg,
    this.rateSource,
    this.paymentReference,
    this.paidAt,
  });

  factory RiderActiveTrip.fromJson(Map<String, dynamic> json) {
    DateTime? parseDate(dynamic raw) {
      if (raw is String) return DateTime.tryParse(raw);
      return null;
    }

    return RiderActiveTrip(
      id: (json['order_id'] ?? '').toString(),
      produceRequestId: (json['produce_request_id'] ?? '').toString(),
      status: (json['status'] ?? 'ACCEPTED').toString(),
      rawStatus: (json['raw_status'] ?? '').toString(),
      cropName: (json['crop_name'] ?? '—').toString(),
      weightKg: ((json['weight_kg'] ?? 0) as num).toDouble(),
      dropoffMandi: json['dropoff_mandi']?.toString(),
      dropoffStall: json['dropoff_stall']?.toString(),
      dropoffAddress: json['dropoff_address']?.toString(),
      pickupAddress: json['pickup_address']?.toString(),
      pickupLandmark: json['pickup_landmark']?.toString(),
      pickupLatitude: (json['pickup_latitude'] as num?)?.toDouble(),
      pickupLongitude: (json['pickup_longitude'] as num?)?.toDouble(),
      farmerFullName: json['farmer_full_name']?.toString(),
      farmerPhoneNumber: json['farmer_phone_number']?.toString(),
      farmAddress: json['farm_address']?.toString(),
      createdAt: parseDate(json['created_at']),
      completedAt: parseDate(json['completed_at']),
      poolId: json['pool_id']?.toString(),
      riderExpectedPickupAt: parseDate(json['rider_expected_pickup_at']),
      pickupWindowStart: parseDate(json['pickup_window_start']),
      pickupWindowEnd: parseDate(json['pickup_window_end']),
      settlementId: json['settlement_id']?.toString(),
      paymentStatus: json['payment_status']?.toString(),
      grossAmount: (json['gross_amount'] as num?)?.toDouble(),
      riderFare: (json['rider_fare'] as num?)?.toDouble(),
      platformFee: (json['platform_fee'] as num?)?.toDouble(),
      netPayout: (json['net_payout'] as num?)?.toDouble(),
      ratePerKg: (json['rate_per_kg'] as num?)?.toDouble(),
      rateSource: json['rate_source']?.toString(),
      paymentReference: json['payment_reference']?.toString(),
      paidAt: parseDate(json['paid_at']),
    );
  }

  /// The Trip's UUID — used for every operational action.
  final String id;

  /// The linked ProduceRequest's UUID — informational, and useful for
  /// cross-referencing with the farmer-side view.
  final String produceRequestId;

  /// Normalized status: ACCEPTED / PICKED_UP / COMPLETED.
  final String status;

  /// Raw backend status before normalization.
  final String rawStatus;

  final String cropName;
  final double weightKg;

  /// Primary dropoff label shown on the card and in the sheet.
  final String? dropoffMandi;

  /// Stall / shop / bay number at the mandi, when provided.
  final String? dropoffStall;

  /// Legacy composite dropoff string; used as a fallback in the sheet.
  final String? dropoffAddress;

  final String? pickupAddress;
  final String? pickupLandmark;
  final double? pickupLatitude;
  final double? pickupLongitude;

  final String? farmerFullName;
  final String? farmerPhoneNumber;
  final String? farmAddress;

  final DateTime? createdAt;
  final DateTime? completedAt;
  final String? poolId;
  final DateTime? riderExpectedPickupAt;
  final DateTime? pickupWindowStart;
  final DateTime? pickupWindowEnd;
  final String? settlementId;
  final String? paymentStatus;
  final double? grossAmount;
  final double? riderFare;
  final double? platformFee;
  final double? netPayout;
  final double? ratePerKg;
  final String? rateSource;
  final String? paymentReference;
  final DateTime? paidAt;

  bool get isPaid => (paymentStatus ?? '').toUpperCase() == 'PAID';

  // ---------------------------------------------------------------------
  // Convenience accessors
  // ---------------------------------------------------------------------

  /// True when the backend has populated the farmer's contact number.
  bool get hasFarmerContact =>
      farmerPhoneNumber != null && farmerPhoneNumber!.trim().isNotEmpty;

  /// Human-readable pickup line for the sheet, preferring the address
  /// string the farmer actually typed over raw coordinates.
  String get displayPickup {
    if (pickupAddress != null && pickupAddress!.trim().isNotEmpty) {
      return pickupAddress!.trim();
    }
    if (pickupLatitude != null && pickupLongitude != null) {
      return '${pickupLatitude!.toStringAsFixed(4)}, '
          '${pickupLongitude!.toStringAsFixed(4)}';
    }
    return '—';
  }

  /// Query string to hand to Google Maps — address when available, else
  /// coordinates.
  String get mapsPickupQuery {
    if (pickupAddress != null && pickupAddress!.trim().isNotEmpty) {
      return pickupAddress!.trim();
    }
    if (pickupLatitude != null && pickupLongitude != null) {
      return '$pickupLatitude,$pickupLongitude';
    }
    return '';
  }

  /// Query string for the mandi dropoff, used by the "Navigate" button on
  /// the pickup-up state.
  String get mapsDropoffQuery {
    final mandi = (dropoffMandi ?? '').trim();
    if (mandi.isNotEmpty) return mandi;
    final legacy = (dropoffAddress ?? '').trim();
    return legacy;
  }

  /// Short, stable reference for the list card — `#KR-<6hex>` matching
  /// the convention used on the farmer order-history screen.
  String get shortRef {
    final compact = id.replaceAll('-', '');
    final take = compact.length >= 6 ? compact.substring(0, 6) : compact;
    return '#KR-${take.toUpperCase()}';
  }
}

// ============================================================================
// Tab
// ============================================================================

/// Tab 1 of the rider shell — the rider's active and recently completed
/// trips, rendered as a flat, minimal list matching the farmer "My Orders"
/// screen.
///
/// ## Layout
///
///   1. Top horizontal filter chips: All / Accepted / Picked Up /
///      Completed. Default is All.
///   2. A scrollable list of 3-line cards. Every card is a pure summary:
///      crop + weight + status badge, dropoff line, order ref + date.
///      No operational controls live in the list view.
///   3. Tapping any card opens [_TripOperationalSheet] — the state-aware
///      operational surface that carries the CALL FARMER button, the
///      pickup OTP input, the cancel action, and the mark-delivered
///      action, depending on the trip's status.
///
/// All operational actions live in the sheet so the list stays scannable.
class RiderActiveTab extends StatefulWidget {
  const RiderActiveTab({super.key});

  @override
  State<RiderActiveTab> createState() => _RiderActiveTabState();
}

class _RiderActiveTabState extends State<RiderActiveTab>
    with AutomaticKeepAliveClientMixin {
  final List<RiderActiveTrip> _trips = [];

  /// IDs of trips with an in-flight background action (currently only the
  /// delivery-completion flow, which can take a few seconds while the
  /// photo uploads). Kept on the parent so a pull-to-refresh mid-upload
  /// doesn't lose track of which card is busy.
  final Set<String> _busyTripIds = {};

  bool _isLoading = true;
  String? _error;

  /// Active filter chip. Index 0 = All (default).
  int _activeFilterIndex = 0;

  /// Filter definitions. `tag == null` matches every status — this is the
  /// "All" chip. The `tag` values here MUST match the status strings the
  /// backend returns (see `RiderActiveTrip.status`).
  static const List<({String label, String? tag})> _filters = [
    (label: 'All', tag: null),
    (label: 'Accepted', tag: 'ACCEPTED'),
    (label: 'Picked Up', tag: 'PICKED_UP'),
    (label: 'Pooled', tag: 'POOLED'),
  ];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    kPaymentEventsNotifier.addListener(_onExternalPaymentEvent);
    WidgetsBinding.instance.addPostFrameCallback((_) => _fetch());
  }

  @override
  void dispose() {
    kPaymentEventsNotifier.removeListener(_onExternalPaymentEvent);
    super.dispose();
  }

  void _onExternalPaymentEvent() {
    if (mounted) _fetch();
  }

  Map<String, String> _headers(AuthProvider auth, {bool json = false}) {
    final h = <String, String>{
      'Authorization': 'Bearer ${auth.token}',
      'Accept': 'application/json',
    };
    if (json) h['Content-Type'] = 'application/json';
    return h;
  }

  // -------------------------------------------------------------------------
  // Fetch
  // -------------------------------------------------------------------------

  Future<void> _fetch() async {
    final auth = context.read<AuthProvider>();
    if (auth.token == null) {
      setState(() {
        _isLoading = false;
        _error = AppStrings.tr('Not signed in.');
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final response = await http.get(
        Uri.parse('$kApiBaseUrl/rider/trips/active'),
        headers: _headers(auth),
      );
      if (!mounted) return;

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        final List<dynamic> items;
        if (decoded is List) {
          items = decoded;
        } else if (decoded is Map<String, dynamic>) {
          items = [decoded];
        } else {
          items = const [];
        }

        setState(() {
          _trips
            ..clear()
            ..addAll(
              items.map(
                (e) => RiderActiveTrip.fromJson(e as Map<String, dynamic>),
              ),
            );
          _isLoading = false;
        });
      } else if (response.statusCode == 404) {
        setState(() {
          _trips.clear();
          _isLoading = false;
        });
      } else {
        setState(() {
          _error = _extractError(response) ??
              AppStrings.tr(
                'Failed to load trips (HTTP {code}).',
                args: {'code': '${response.statusCode}'},
              );
          _isLoading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = AppStrings.tr(
          'Network error: {err}',
          args: {'err': '$e'},
        );
        _isLoading = false;
      });
    }
  }

  // -------------------------------------------------------------------------
  // Operational actions (invoked from the sheet)
  // -------------------------------------------------------------------------

  /// Verify the pickup OTP via `POST /rider/trips/{id}/verify-otp`.
  ///
  /// The backend flips both the Trip and the linked ProduceRequest to
  /// `PICKED_UP`, so the next fetch will show the trip in the "Picked Up"
  /// filter.
  Future<OtpSubmitResult> _submitOtp(
    RiderActiveTrip trip,
    String otp,
  ) async {
    final auth = context.read<AuthProvider>();
    if (auth.token == null) return OtpSubmitResult.otherError;

    try {
      final resp = await http.post(
        Uri.parse('$kApiBaseUrl/rider/trips/${trip.id}/verify-otp'),
        headers: _headers(auth, json: true),
        body: jsonEncode({'otp': otp}),
      );

      if (resp.statusCode == 400) {
        // The backend returns 400 for "Invalid OTP" — distinguish that
        // from generic 400s by inspecting the detail string.
        final detail = _extractError(resp) ?? '';
        if (detail.toLowerCase().contains('otp')) {
          return OtpSubmitResult.invalidOtp;
        }
        return OtpSubmitResult.otherError;
      }
      if (resp.statusCode != 200) return OtpSubmitResult.otherError;

      return OtpSubmitResult.success;
    } catch (_) {
      return OtpSubmitResult.otherError;
    }
  }

  /// Cancel an ACCEPTED trip via `POST /rider/trips/{id}/cancel`.
  ///
  /// On success the backend reverts the underlying ProduceRequest to
  /// PENDING so another rider can pick it up, and the trip disappears
  /// from this list.
  Future<bool> _cancelTrip(RiderActiveTrip trip) async {
    final auth = context.read<AuthProvider>();
    if (auth.token == null) return false;

    try {
      final resp = await http.post(
        Uri.parse('$kApiBaseUrl/rider/trips/${trip.id}/cancel'),
        headers: _headers(auth, json: true),
      );
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Upload proof of delivery, then transition the trip to DELIVERED.
  ///
  /// The delivery-completion flow is unchanged from the previous
  /// implementation — a photo must be uploaded first (the backend does
  /// not accept a DELIVERED transition without it), then the trip status
  /// is PATCHed. This function is called from inside the photo dialog.
  Future<DeliveryResult> _uploadProofAndDeliver(
    RiderActiveTrip trip,
    Uint8List imageBytes,
    String sourceFilename,
  ) async {
    if (!_kCompletableTripStatuses.contains(trip.status)) {
      return DeliveryResult.failure(
        AppStrings.tr(
          'Trip must be PICKED_UP before completing (current: {status}).',
          args: {'status': trip.status},
        ),
      );
    }

    final auth = context.read<AuthProvider>();
    if (auth.token == null) {
      return DeliveryResult.failure(AppStrings.tr('Not signed in.'));
    }

    final uploaded = await uploadDeliveryProofPhoto(
      token: auth.token!,
      imageBytes: imageBytes,
      sourceFilename: sourceFilename,
      timeout: _kUploadTimeout,
    );

    if (uploaded.imageUrl == null) {
      return DeliveryResult.failure(
        uploaded.errorMessage ?? AppStrings.tr('Photo upload failed.'),
      );
    }

    try {
      // ----- Step 2: transition the trip to DELIVERED ---------------
      final patchResp = await http
          .patch(
            Uri.parse('$kApiBaseUrl/trips/${trip.id}/status'),
            headers: _headers(auth, json: true),
            body: jsonEncode({'status': 'DELIVERED'}),
          )
          .timeout(_kUploadTimeout);

      if (patchResp.statusCode != 200) {
        return DeliveryResult.failure(
          _extractErrorDetail(
            patchResp,
            AppStrings.tr(
              'Could not mark trip delivered (HTTP {code}).',
              args: {'code': '${patchResp.statusCode}'},
            ),
          ),
        );
      }

      return const DeliveryResult.success();
    } on TimeoutException catch (e) {
      debugPrint('Upload Error (timeout): $e');
      return DeliveryResult.failure(
        AppStrings.tr('Connection timed out. Please check backend server.'),
      );
    } catch (e) {
      debugPrint('Upload Error: $e');
      return DeliveryResult.failure(
        AppStrings.tr('Error: {err}', args: {'err': '$e'}),
      );
    }
  }

  /// Pulls the human-readable reason out of a FastAPI error response.
  String _extractErrorDetail(http.Response response, String fallback) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['detail'] != null) {
        final detail = decoded['detail'].toString();
        return detail.length > 300 ? '${detail.substring(0, 300)}…' : detail;
      }
    } catch (_) {
      // Body wasn't JSON — fall through to the generic message.
    }
    return fallback;
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
  // Sheet launcher
  // -------------------------------------------------------------------------

  /// Opens the operational detail sheet for [trip].
  ///
  /// After the sheet pops — regardless of whether an action ran — we
  /// silently refresh the list so the card reflects the new status.
  Future<void> _openTripSheet(RiderActiveTrip trip) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _TripOperationalSheet(
        trip: trip,
        onVerifyOtp: (otp) => _submitOtp(trip, otp),
        onCancel: () => _cancelTrip(trip),
        onMarkDelivered: () => _openDeliveryProofDialog(trip),
        onGenerateQr: () => _openTripPaymentQr(trip),
      ),
    );
    if (!mounted) return;
    await _fetch();
  }

  Future<bool> _openTripPaymentQr(RiderActiveTrip trip) async {
    final auth = context.read<AuthProvider>();
    if (auth.token == null) return false;
    final paid = await showTripPaymentQrDialog(
      context,
      token: auth.token!,
      tripId: trip.id,
    );
    if (paid && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.trAsync('Payment received! Rider & Farmer accounts updated.'),
          ),
          backgroundColor: kRiderGreen,
        ),
      );
      await _fetch();
    }
    return paid;
  }

  Future<void> _openPoolPaymentQr(String poolId) async {
    final auth = context.read<AuthProvider>();
    if (auth.token == null) return;
    final paid = await showPoolPaymentQrDialog(
      context,
      token: auth.token!,
      poolId: poolId,
    );
    if (paid && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.trAsync('Pool payment received! Auto-split complete.'),
          ),
          backgroundColor: kRiderGreen,
        ),
      );
      await _fetch();
    }
  }

  /// Shows the photo-upload proof dialog, returns `true` on a successful
  /// upload + status transition.
  Future<bool> _openDeliveryProofDialog(RiderActiveTrip trip) async {
    if (!_kCompletableTripStatuses.contains(trip.status)) {
      return false;
    }
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => DeliveryProofDialog(
        onSubmit: (bytes, filename) =>
            _uploadProofAndDeliver(trip, bytes, filename),
      ),
    );
    return result == true;
  }

  Future<void> _openPoolDeliveryProofDialog(
    String poolId,
    List<RiderActiveTrip> poolTrips,
  ) async {
    final allPickedUp = poolTrips.isNotEmpty &&
        poolTrips.every((t) =>
            t.status == 'PICKED_UP' ||
            t.status == 'COMPLETED' ||
            t.status == 'DELIVERED');
    final isDelivered = poolTrips.every(
        (t) => t.status == 'COMPLETED' || t.status == 'DELIVERED');
    if (!allPickedUp || isDelivered) return;

    final auth = context.read<AuthProvider>();
    if (auth.token == null) return;

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => DeliveryProofDialog(
        subtitleText: context.trAsync(
          'Take a photo of the delivered pooled produce at the mandi. '
          'This marks all pooled pickups as delivered.',
        ),
        onSubmit: (bytes, filename) => deliverPoolWithProof(
          token: auth.token!,
          poolId: poolId,
          imageBytes: bytes,
          sourceFilename: filename,
        ),
      ),
    );

    if (result == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.trAsync('Pool marked as delivered!')),
          backgroundColor: kRiderGreen,
        ),
      );
      await _fetch();
    }
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  /// Visible list after applying the active filter chip.
  List<RiderActiveTrip> get _filteredTrips {
    final tag = _filters[_activeFilterIndex].tag;
    if (tag == null) return _trips;
    if (tag == 'POOLED') {
      return _trips.where((t) => t.poolId != null && t.poolId!.isNotEmpty).toList(growable: false);
    }
    return _trips.where((t) => t.status == tag).toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return ErrorView(message: _error!, onRetry: _fetch);
    }

    return Column(
      children: [
        _buildFilterBar(),
        Expanded(child: _buildBody()),
      ],
    );
  }

  Widget _buildFilterBar() {
    return SegmentedFilterBar<int>(
      options: [
        for (int i = 0; i < _filters.length; i++)
          SegmentedFilterOption(
            value: i,
            label: context.tr(_filters[i].label),
          ),
      ],
      selectedValue: _activeFilterIndex,
      onChanged: (i) => setState(() => _activeFilterIndex = i),
      accentColor: kRiderGreen,
    );
  }

  Widget _buildBody() {
    if (_trips.isEmpty) {
      return RefreshIndicator(
        onRefresh: _fetch,
        child: ListView(
          children: [
            const SizedBox(height: 160),
            const Icon(
              Icons.delivery_dining_outlined,
              size: 64,
              color: Colors.black26,
            ),
            const SizedBox(height: 12),
            Center(
              child: Text(
                context.tr('No active trips. Accept a request to get started.'),
                style: const TextStyle(fontSize: 15, color: Colors.black54),
              ),
            ),
          ],
        ),
      );
    }

    if (_filters[_activeFilterIndex].tag == 'POOLED') {
      final Map<String, List<RiderActiveTrip>> poolGroups = {};
      for (final trip in _trips) {
        if (trip.poolId != null && trip.poolId!.isNotEmpty) {
          poolGroups.putIfAbsent(trip.poolId!, () => []).add(trip);
        }
      }

      if (poolGroups.isEmpty) {
        return RefreshIndicator(
          onRefresh: _fetch,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 80),
            children: [
              Icon(Icons.groups_outlined, size: 56, color: Colors.grey.shade400),
              const SizedBox(height: 12),
              Center(
                child: Text(
                  context.tr('No active pooled trips.'),
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 14, color: Colors.grey.shade700),
                ),
              ),
            ],
          ),
        );
      }

      final poolIds = poolGroups.keys.toList();
      return RefreshIndicator(
        onRefresh: _fetch,
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          itemCount: poolIds.length,
          itemBuilder: (context, index) {
            final pid = poolIds[index];
            final poolTrips = poolGroups[pid]!;
            return _GroupedPoolCard(
              poolId: pid,
              trips: poolTrips,
              onMarkDelivered: () => _openPoolDeliveryProofDialog(pid, poolTrips),
              onGeneratePaymentQr: () => _openPoolPaymentQr(pid),
              onTap: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => RiderPoolDetailScreen(
                      poolId: pid,
                      isActiveTrip: true,
                    ),
                  ),
                );
                if (mounted) _fetch();
              },
            );
          },
        ),
      );
    }

    final visible = _filteredTrips;

    if (visible.isEmpty) {
      return RefreshIndicator(
        onRefresh: _fetch,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding:
              const EdgeInsets.symmetric(horizontal: 32, vertical: 80),
          children: [
            Icon(
              Icons.filter_alt_off_outlined,
              size: 56,
              color: Colors.grey.shade400,
            ),
            const SizedBox(height: 12),
            Center(
              child: Text(
                context.tr('No trips match this filter.'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey.shade700,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _fetch,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        itemCount: visible.length,
        itemBuilder: (context, index) {
          final trip = visible[index];
          return _TripCard(
            trip: trip,
            isBusy: _busyTripIds.contains(trip.id),
            onTap: () => _openTripSheet(trip),
          );
        },
      ),
    );
  }
}

// ============================================================================
// Trip card — exactly 3 lines, matching the farmer "My Orders" style
// ============================================================================

class _TripCard extends StatelessWidget {
  const _TripCard({
    required this.trip,
    required this.isBusy,
    required this.onTap,
  });

  final RiderActiveTrip trip;
  final bool isBusy;
  final VoidCallback onTap;

  /// "Oct 18, 2026" — three-letter month, comma before the year. Matches
  /// the format used on the farmer-side Order History card.
  String _formatDate(DateTime d) {
    final local = d.toLocal();
    return '${AppStrings.trShortMonth(local.month)} ${local.day}, ${local.year}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Line 1: "CropName · 500 kg" + status badge
    final headerLine =
        '${trip.cropName} · ${trip.weightKg.toStringAsFixed(0)} ${context.tr('kg')}';

    // Line 2: Dropoff label — mandi name preferred, fall back to the
    // legacy composite dropoff string.
    final dropoffLabel = () {
      final mandi = (trip.dropoffMandi ?? '').trim();
      if (mandi.isNotEmpty) return mandi;
      final legacy = (trip.dropoffAddress ?? '').trim();
      if (legacy.isNotEmpty) return legacy;
      return '—';
    }();

    // Line 3: "#KR-EB4953 · Oct 18, 2026"
    final dateLabel =
        trip.createdAt != null ? _formatDate(trip.createdAt!) : '—';
    final subLine = '${trip.shortRef} · $dateLabel';

    return Card(
      elevation: 1,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: isBusy ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ----- Line 1: crop · weight  |  status badge -----------
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      headerLine,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  _TripStatusBadge(status: trip.status),
                ],
              ),
              const SizedBox(height: 8),

              if (trip.riderExpectedPickupAt != null) ...[
                Row(
                  children: [
                    const Icon(Icons.schedule, size: 14, color: kRiderGreen),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        context.tr(
                          'Pickup: {addr}',
                          args: {
                            'addr': '${trip.riderExpectedPickupAt!.toLocal().day}/${trip.riderExpectedPickupAt!.toLocal().month} ${trip.riderExpectedPickupAt!.toLocal().hour.toString().padLeft(2, '0')}:${trip.riderExpectedPickupAt!.toLocal().minute.toString().padLeft(2, '0')}',
                          },
                        ),
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: kRiderGreen,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
              ],

              // ----- Line 2: dropoff ----------------------------------
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.flag_outlined,
                    size: 15,
                    color: Color(0xFF6B7280),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      context.tr(
                        'Dropoff: {dropoff}',
                        args: {'dropoff': dropoffLabel},
                      ),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF1C1B1F),
                        fontSize: 13,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),

              // ----- Line 3: ref · date -------------------------------
              Row(
                children: [
                  Expanded(
                    child: Text(
                      subLine,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (isBusy)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else ...[
                    if (trip.status == 'COMPLETED')
                      Container(
                        margin: const EdgeInsets.only(right: 6),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: trip.isPaid
                              ? const Color(0xFFE8F5E9)
                              : Colors.amber.shade50,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: trip.isPaid
                                ? const Color(0xFFA5D6A7)
                                : Colors.amber.shade300,
                          ),
                        ),
                        child: Text(
                          context.trStatus(trip.isPaid ? 'PAID' : 'QR PAY'),
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: trip.isPaid
                                ? const Color(0xFF166534)
                                : Colors.amber.shade900,
                          ),
                        ),
                      ),
                    Icon(
                      Icons.chevron_right,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ],
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

class _TripStatusBadge extends StatelessWidget {
  const _TripStatusBadge({required this.status});

  final String status;

  static const Map<String, (Color, Color)> _colors = {
    'ACCEPTED':  (Color(0xFF1D4ED8), Color(0x261D4ED8)), // blue
    'PICKED_UP': (Color(0xFF6D28D9), Color(0x266D28D9)), // purple
    'COMPLETED': (Color(0xFF166534), Color(0x2616A34A)), // green
  };

  @override
  Widget build(BuildContext context) {
    final normalized = status.toUpperCase();
    final (fg, bg) = _colors[normalized] ??
        (Colors.black54, Colors.black12);

    // Display the human-friendly label for the client-facing status.
    final label = normalized == 'PICKED_UP' ? 'PICKED UP' : normalized;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: fg),
      ),
      child: Text(
        context.trStatus(label),
        style: TextStyle(
          color: fg,
          fontWeight: FontWeight.bold,
          fontSize: 10.5,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

// ============================================================================
// Operational detail sheet — state-aware actions
// ============================================================================

/// The full operational surface for a single trip.
///
/// The content depends entirely on `trip.status`:
///
///   * **ACCEPTED** — farmer contact details, CALL FARMER button, inline
///     pickup-OTP input + verify button, and a cancel-trip button that
///     opens a confirmation modal.
///   * **PICKED_UP** — cancellation is locked and hidden. Shows the
///     mandi dropoff details, stall number, a "Navigate to Mandi"
///     button, and the delivery-completion action
///     ("✅ Mark as Delivered / Unloaded").
///   * **COMPLETED** — read-only digital receipt: no actions.
///
/// Actions are wired through callback props so the parent tab remains
/// the single owner of networking. The sheet pops itself on success and
/// the parent refreshes the underlying list.
class _TripOperationalSheet extends StatefulWidget {
  const _TripOperationalSheet({
    required this.trip,
    required this.onVerifyOtp,
    required this.onCancel,
    required this.onMarkDelivered,
    required this.onGenerateQr,
  });

  final RiderActiveTrip trip;
  final Future<OtpSubmitResult> Function(String otp) onVerifyOtp;
  final Future<bool> Function() onCancel;
  final Future<bool> Function() onMarkDelivered;
  final Future<bool> Function() onGenerateQr;

  @override
  State<_TripOperationalSheet> createState() => _TripOperationalSheetState();
}

class _TripOperationalSheetState extends State<_TripOperationalSheet> {
  final TextEditingController _otpController = TextEditingController();

  bool _isSubmitting = false;
  bool _deliveredNow = false;
  bool _paidNow = false;
  String? _error;

  @override
  void dispose() {
    _otpController.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Action handlers
  // -------------------------------------------------------------------------

  Future<void> _verifyOtp() async {
    final otp = _otpController.text.trim();
    if (otp.length != 4) {
      setState(() => _error = AppStrings.tr('Enter the 4-digit OTP.'));
      return;
    }

    setState(() {
      _isSubmitting = true;
      _error = null;
    });

    final result = await widget.onVerifyOtp(otp);
    if (!mounted) return;

    if (result == OtpSubmitResult.success) {
      Navigator.of(context).pop();
      return;
    }

    setState(() {
      _isSubmitting = false;
      _error = result == OtpSubmitResult.invalidOtp
          ? AppStrings.tr('Invalid OTP. Please check with the farmer.')
          : AppStrings.tr('Could not verify OTP. Please try again.');
    });
  }

  Future<void> _confirmAndCancel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(dialogCtx.tr('Cancel this trip?')),
        content: Text(
          dialogCtx.tr(
            'The farmer will be notified and the request will go back to '
            'the Available feed for another rider to accept. This cannot '
            'be undone.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: Text(dialogCtx.tr('Keep Trip')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade600,
            ),
            child: Text(dialogCtx.tr('Cancel Trip')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _isSubmitting = true;
      _error = null;
    });

    final ok = await widget.onCancel();
    if (!mounted) return;

    if (ok) {
      Navigator.of(context).pop();
      return;
    }

    setState(() {
      _isSubmitting = false;
      _error = AppStrings.tr(
        'Could not cancel the trip. Please try again.',
      );
    });
  }

  Future<void> _markDelivered() async {
    setState(() {
      _isSubmitting = true;
      _error = null;
    });

    final success = await widget.onMarkDelivered();
    if (!mounted) return;

    if (success) {
      // Transition in-place to Delivered so the QR payment button
      // immediately replaces "Mark as Delivered".
      setState(() {
        _isSubmitting = false;
        _deliveredNow = true;
      });
      return;
    }

    // The photo dialog handles its own error messages; if we land here
    // the user probably cancelled the dialog. Just reset the loading
    // state without surfacing an error.
    setState(() => _isSubmitting = false);
  }

  Future<void> _generateQr() async {
    setState(() {
      _isSubmitting = true;
      _error = null;
    });
    final paid = await widget.onGenerateQr();
    if (!mounted) return;
    setState(() {
      _isSubmitting = false;
      if (paid) _paidNow = true;
    });
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ----- Drag handle ----------------------------------
                Center(
                  child: Container(
                    width: 44,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // ----- Header row -----------------------------------
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${widget.trip.cropName} · '
                            '${widget.trip.weightKg.toStringAsFixed(0)} ${context.tr('kg')}',
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            widget.trip.shortRef,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    _TripStatusBadge(
                      status: _deliveredNow ? 'COMPLETED' : widget.trip.status,
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // ----- State-specific body --------------------------
                if (!_deliveredNow && widget.trip.status == 'ACCEPTED')
                  _buildAcceptedBody(theme)
                else if (!_deliveredNow && widget.trip.status == 'PICKED_UP')
                  _buildPickedUpBody(theme)
                else
                  _buildCompletedBody(theme),

                // ----- Inline error --------------------------------
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer
                          .withOpacity(0.4),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.error_outline,
                          size: 16,
                          color: theme.colorScheme.error,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _error!,
                            style: TextStyle(
                              color: theme.colorScheme.error,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // ACCEPTED state — farmer contact + OTP + cancel
  // -------------------------------------------------------------------------

  Widget _buildAcceptedBody(ThemeData theme) {
    final exp = widget.trip.riderExpectedPickupAt?.toLocal();
    final winStart = widget.trip.pickupWindowStart?.toLocal();
    final winEnd = widget.trip.pickupWindowEnd?.toLocal();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (exp != null || winEnd != null) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.blue.shade200),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (exp != null)
                  Row(
                    children: [
                      Icon(Icons.schedule, size: 16, color: Colors.blue.shade800),
                      const SizedBox(width: 8),
                      Text(
                        context.tr(
                          'Expected Pickup: {time}',
                          args: {
                            'time': '${exp.day}/${exp.month} ${context.tr('at')} ${exp.hour.toString().padLeft(2, '0')}:${exp.minute.toString().padLeft(2, '0')}',
                          },
                        ),
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.blue.shade900),
                      ),
                    ],
                  ),
                if (winStart != null && winEnd != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    context.tr(
                      'Pickup Window: {window}',
                      args: {
                        'window': '${winStart.day}/${winStart.month} ${winStart.hour.toString().padLeft(2, '0')}:${winStart.minute.toString().padLeft(2, '0')} — ${winEnd.day}/${winEnd.month} ${winEnd.hour.toString().padLeft(2, '0')}:${winEnd.minute.toString().padLeft(2, '0')}',
                      },
                    ),
                    style: TextStyle(fontSize: 12, color: Colors.blue.shade800),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
        ],

        // ----- Farmer contact card -----------------------------------
        _FarmerContactCard(trip: widget.trip),

        const SizedBox(height: 16),

        // ----- Pickup OTP input --------------------------------------
        Text(
          context.tr('PICKUP VERIFICATION'),
          style: theme.textTheme.labelMedium?.copyWith(
            color: const Color(0xFF6B7280),
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
            fontSize: 11,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFFFFF7E0),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: const Color(0xFFFFE0A3),
              width: 1.2,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                context.tr('Ask the farmer for the 4-digit code on their screen.'),
                style: const TextStyle(
                  fontSize: 12.5,
                  color: Color(0xFF8A5A00),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _otpController,
                enabled: !_isSubmitting,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(4),
                ],
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 26,
                  letterSpacing: 8,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF8A5A00),
                ),
                decoration: InputDecoration(
                  hintText: '••••',
                  hintStyle: const TextStyle(
                    letterSpacing: 8,
                    color: Color(0xFFC9B27F),
                  ),
                  counterText: '',
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(
                      color: Color(0xFF8A5A00),
                      width: 1.6,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _isSubmitting ? null : _verifyOtp,
                  style: FilledButton.styleFrom(
                    backgroundColor: kRiderGreen,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  icon: _isSubmitting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.check, size: 18),
                  label: Text(
                    context.tr(_isSubmitting ? 'Verifying…' : 'Verify OTP'),
                  ),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 20),

        // ----- Cancel trip ------------------------------------------
        OutlinedButton.icon(
          onPressed: _isSubmitting ? null : _confirmAndCancel,
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.red.shade700,
            side: BorderSide(color: Colors.red.shade300),
            padding: const EdgeInsets.symmetric(vertical: 14),
            textStyle: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
          icon: const Icon(Icons.close, size: 18),
          label: Text(context.tr('Reject / Cancel Trip')),
        ),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // PICKED_UP state — mandi dropoff + deliver (NO cancel)
  // -------------------------------------------------------------------------

  Widget _buildPickedUpBody(ThemeData theme) {
    final mandi = (widget.trip.dropoffMandi ?? '').trim();
    final stall = (widget.trip.dropoffStall ?? '').trim();
    final legacy = (widget.trip.dropoffAddress ?? '').trim();
    final dropoffDisplay =
        mandi.isNotEmpty ? mandi : (legacy.isNotEmpty ? legacy : '—');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ----- Dropoff card ------------------------------------------
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: kRiderGreen.withOpacity(0.06),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: kRiderGreen.withOpacity(0.30)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.storefront_outlined,
                    color: kRiderGreen,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    context.tr('Dropoff — Mandi Unloading'),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: kRiderGreen,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _SheetInfoRow(
                icon: Icons.place_outlined,
                label: context.tr('Mandi'),
                value: dropoffDisplay,
              ),
              if (stall.isNotEmpty) ...[
                const SizedBox(height: 8),
                _SheetInfoRow(
                  icon: Icons.tag,
                  label: context.tr('Stall'),
                  value: stall,
                ),
              ],
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () {
                    final query = widget.trip.mapsDropoffQuery;
                    if (query.isNotEmpty) {
                      launchMaps(context, query);
                    }
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: kRiderGreen,
                    side: BorderSide(
                      color: kRiderGreen.withOpacity(0.4),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  icon: const Icon(Icons.navigation_outlined, size: 18),
                  label: Text(context.tr('Navigate to Mandi')),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // ----- Locked-cancellation notice ----------------------------
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 10,
          ),
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.grey.shade300),
          ),
          child: Row(
            children: [
              Icon(
                Icons.lock_outline,
                size: 16,
                color: Colors.grey.shade700,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  context.tr('Cancellation is locked after pickup verification.'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.grey.shade800,
                  ),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 20),

        // ----- Mark as Delivered -------------------------------------
        FilledButton.icon(
          onPressed: _isSubmitting ? null : _markDelivered,
          style: FilledButton.styleFrom(
            backgroundColor: kRiderGreen,
            padding: const EdgeInsets.symmetric(vertical: 15),
            textStyle: const TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
          ),
          icon: _isSubmitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.check_circle_outline, size: 20),
          label: Text(
            context.tr(
              _isSubmitting
                  ? 'Completing…'
                  : '✅ Mark as Delivered / Unloaded',
            ),
          ),
        ),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // COMPLETED state — read-only receipt
  // -------------------------------------------------------------------------

  Widget _buildCompletedBody(ThemeData theme) {
    final mandi = (widget.trip.dropoffMandi ?? '').trim();
    final completedAt = widget.trip.completedAt;
    final isPaid = widget.trip.isPaid || _paidNow;
    final gross = widget.trip.grossAmount;
    final riderFare = widget.trip.riderFare;
    final platformFee = widget.trip.platformFee;
    final netPayout = widget.trip.netPayout;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFFE8F5E9),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFA5D6A7)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.verified_outlined,
                    color: Color(0xFF166534),
                    size: 22,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      context.tr(
                        isPaid ? 'Delivery & Payment Complete' : 'Delivery Complete',
                      ),
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: const Color(0xFF166534),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _SheetInfoRow(
                icon: Icons.eco_outlined,
                label: context.tr('Crop'),
                value: '${widget.trip.cropName} · '
                    '${widget.trip.weightKg.toStringAsFixed(0)} ${context.tr('kg')}',
              ),
              const SizedBox(height: 8),
              _SheetInfoRow(
                icon: Icons.storefront_outlined,
                label: context.tr('Delivered to'),
                value: mandi.isNotEmpty ? mandi : '—',
              ),
              if (completedAt != null) ...[
                const SizedBox(height: 8),
                _SheetInfoRow(
                  icon: Icons.schedule_outlined,
                  label: context.tr('Completed on'),
                  value: _formatCompletedAt(completedAt),
                ),
              ],
              const SizedBox(height: 8),
              _SheetInfoRow(
                icon: Icons.receipt_long_outlined,
                label: context.tr('Reference'),
                value: widget.trip.shortRef,
              ),
              if (widget.trip.paymentReference != null) ...[
                const SizedBox(height: 8),
                _SheetInfoRow(
                  icon: Icons.qr_code_2_outlined,
                  label: context.tr('Payment Ref'),
                  value: widget.trip.paymentReference!,
                ),
              ],
            ],
          ),
        ),
        if (gross != null) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        context.tr('PAYMENT BREAKDOWN'),
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF6B7280),
                          letterSpacing: 0.8,
                        ),
                      ),
                    ),
                    Text(
                      context.trStatus(isPaid ? 'PAID ✅' : 'PENDING QR'),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: isPaid ? kRiderGreen : Colors.amber.shade900,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _SheetInfoRow(
                  icon: Icons.payments_outlined,
                  label: context.tr('Total Value'),
                  value: formatIndianRupees(gross),
                ),
                if (riderFare != null)
                  _SheetInfoRow(
                    icon: Icons.local_shipping_outlined,
                    label: context.tr('Rider Fare'),
                    value: formatIndianRupees(riderFare),
                  ),
                if (platformFee != null)
                  _SheetInfoRow(
                    icon: Icons.account_balance_outlined,
                    label: context.tr('Platform Fee'),
                    value: formatIndianRupees(platformFee),
                  ),
                if (netPayout != null)
                  _SheetInfoRow(
                    icon: Icons.agriculture_outlined,
                    label: context.tr('Farmer Gets'),
                    value: formatIndianRupees(netPayout),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 16),
        if (!isPaid)
          FilledButton.icon(
            onPressed: _isSubmitting ? null : _generateQr,
            style: FilledButton.styleFrom(
              backgroundColor: kRiderGreen,
              padding: const EdgeInsets.symmetric(vertical: 15),
              textStyle: const TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
            ),
            icon: _isSubmitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.qr_code_2_rounded, size: 22),
            label: Text(context.tr('Generate Payment QR')),
          )
        else
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 12,
            ),
            decoration: BoxDecoration(
              color: const Color(0xFFE8F5E9),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFA5D6A7)),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.check_circle,
                  size: 18,
                  color: Color(0xFF166534),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    context.tr(
                      'Payment done! Earnings updated under your Earnings tab.',
                    ),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF166534),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  String _formatCompletedAt(DateTime d) {
    final local = d.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '${local.day} ${AppStrings.trShortMonth(local.month)} ${local.year} · $hh:$mm';
  }
}

// ============================================================================
// Farmer contact card (used by the operational sheet only)
// ============================================================================

class _FarmerContactCard extends StatelessWidget {
  const _FarmerContactCard({required this.trip});

  final RiderActiveTrip trip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final name = (trip.farmerFullName != null &&
            trip.farmerFullName!.trim().isNotEmpty)
        ? trip.farmerFullName!.trim()
        : context.tr('Farmer');

    final pickup = (trip.pickupAddress != null &&
            trip.pickupAddress!.trim().isNotEmpty)
        ? trip.pickupAddress!.trim()
        : null;

    final phone = (trip.farmerPhoneNumber ?? '').trim();

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kRiderGreen.withOpacity(0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kRiderGreen.withOpacity(0.30)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.agriculture_outlined,
                color: kRiderGreen,
                size: 18,
              ),
              const SizedBox(width: 8),
              Text(
                context.tr('Farmer Contact'),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: kRiderGreen,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Icon(
                Icons.person_outline,
                size: 18,
                color: Colors.black54,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  name,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (phone.isNotEmpty) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(
                  Icons.phone_outlined,
                  size: 18,
                  color: Colors.black54,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '+91 $phone',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (pickup != null) ...[
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Icon(
                    Icons.location_on_outlined,
                    size: 18,
                    color: Colors.black54,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    pickup,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (phone.isNotEmpty) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => launchPhoneCall(context, phone),
                style: FilledButton.styleFrom(
                  backgroundColor: kRiderGreen,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  textStyle: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
                icon: const Icon(Icons.phone, size: 18),
                label: Text(context.tr('📞 CALL FARMER')),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ============================================================================
// Small label/value row used inside the operational sheet
// ============================================================================

class _SheetInfoRow extends StatelessWidget {
  const _SheetInfoRow({
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
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: const Color(0xFF6B7280)),
        const SizedBox(width: 8),
        SizedBox(
          width: 96,
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}

// ============================================================================
// Grouped Pool Card for Active Trips
// ============================================================================

class _GroupedPoolCard extends StatelessWidget {
  const _GroupedPoolCard({
    required this.poolId,
    required this.trips,
    required this.onTap,
    required this.onMarkDelivered,
    required this.onGeneratePaymentQr,
  });

  final String poolId;
  final List<RiderActiveTrip> trips;
  final VoidCallback onTap;
  final VoidCallback onMarkDelivered;
  final VoidCallback onGeneratePaymentQr;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cropName =
        trips.isNotEmpty ? trips.first.cropName : context.tr('Produce');
    final totalWeight = trips.fold<double>(0.0, (acc, t) => acc + t.weightKg);
    final totalFarmers = trips.length;
    final completedPickups = trips
        .where((t) =>
            t.status == 'PICKED_UP' ||
            t.status == 'COMPLETED' ||
            t.status == 'DELIVERED')
        .length;
    final dropoff = trips.isNotEmpty
        ? (trips.first.dropoffMandi ?? context.tr('Mandi Destination'))
        : '—';
    final isDelivered =
        trips.isNotEmpty && trips.every((t) => t.status == 'COMPLETED' || t.status == 'DELIVERED');
    final allPaid =
        trips.isNotEmpty && trips.every((t) => t.isPaid);
    final allPickedUp = totalFarmers > 0 && completedPickups == totalFarmers;

    return Card(
      elevation: 1,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      context.tr(
                        '{crop} (Pooled Trip)',
                        args: {'crop': cropName},
                      ),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: const Color(0xFF1C1B1F),
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: kRiderGreen.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: kRiderGreen),
                    ),
                    child: Text(
                      context.trStatus(isDelivered ? 'DELIVERED' : 'ACTIVE POOL'),
                      style: const TextStyle(
                        color: kRiderGreen,
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(Icons.inventory_2_outlined, size: 16, color: Colors.grey),
                  const SizedBox(width: 6),
                  Text(
                    context.tr(
                      'Combined: {weight} kg',
                      args: {'weight': totalWeight.toStringAsFixed(0)},
                    ),
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  const Icon(Icons.people_alt_outlined, size: 16, color: Colors.grey),
                  const SizedBox(width: 6),
                  Text(
                    context.tr(
                      '{count} Farmer Pickups',
                      args: {'count': '$totalFarmers'},
                    ),
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.check_circle_outline, size: 16, color: Colors.blue),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      context.tr(
                        'Pickup Progress: {done} of {total} completed',
                        args: {
                          'done': '$completedPickups',
                          'total': '$totalFarmers',
                        },
                      ),
                      style: TextStyle(
                        fontSize: 12.5,
                        color: completedPickups == totalFarmers ? kRiderGreen : Colors.blue.shade800,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.storefront_outlined, size: 16, color: Colors.grey),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      context.tr(
                        'Destination: {dropoff}',
                        args: {'dropoff': dropoff},
                      ),
                      style: const TextStyle(fontSize: 12.5, color: Colors.black87),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              if (allPickedUp && !isDelivered) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: onMarkDelivered,
                    icon: const Icon(Icons.check_circle_outline, size: 18),
                    label: Text(
                      context.tr('✅ Mark as Delivered / Unloaded'),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: kRiderGreen,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
              ] else if (isDelivered && !allPaid) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: onGeneratePaymentQr,
                    icon: const Icon(Icons.qr_code_2_rounded, size: 19),
                    label: Text(
                      context.tr('Generate Payment QR'),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: kRiderGreen,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
              ] else if (isDelivered && allPaid) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE8F5E9),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFFA5D6A7)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.check_circle, size: 16, color: Color(0xFF166534)),
                      const SizedBox(width: 6),
                      Text(
                        context.tr('Payment Done ✅'),
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF166534),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    context.tr('Tap to view map & stops'),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: kRiderGreen,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.chevron_right, size: 16, color: kRiderGreen),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
