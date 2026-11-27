import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_strings.dart';
import '../../providers/auth_provider.dart';
import '../payment_qr_dialog.dart';
import '../rider_common.dart';

class RiderPoolDetailScreen extends StatefulWidget {
  const RiderPoolDetailScreen({
    super.key,
    required this.poolId,
    this.isActiveTrip = false,
  });

  final String poolId;
  final bool isActiveTrip;

  @override
  State<RiderPoolDetailScreen> createState() => _RiderPoolDetailScreenState();
}

class _RiderPoolDetailScreenState extends State<RiderPoolDetailScreen> {
  bool _isLoading = true;
  String? _error;
  Map<String, dynamic>? _routeData;

  Position? _currentPosition;
  bool _isAccepting = false;

  final MapController _mapController = MapController();
  double? _riderCapacityKg;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadData();
    });
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    final auth = context.read<AuthProvider>();
    if (auth.token == null) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = AppStrings.tr('Not signed in.');
      });
      return;
    }

    // 1. Resolve Rider GPS position
    double lat = 12.9141; // Default Karnataka center fallback
    double lng = 74.8560;

    try {
      final accResp = await http.get(
        Uri.parse('$kApiBaseUrl/rider/account'),
        headers: {
          'Authorization': 'Bearer ${auth.token}',
          'Accept': 'application/json',
        },
      );
      if (accResp.statusCode == 200) {
        final accJson = jsonDecode(accResp.body);
        _riderCapacityKg = (accJson['payload_capacity_kg'] as num?)?.toDouble();
      }
    } catch (_) {}

    try {
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.whileInUse || perm == LocationPermission.always) {
        final pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.medium,
        );
        _currentPosition = pos;
        lat = pos.latitude;
        lng = pos.longitude;
      }
    } catch (_) {}

    // 2. Fetch Route Optimization & Pool Details
    try {
      final uri = Uri.parse('$kApiBaseUrl/pools/${widget.poolId}/route-optimization').replace(
        queryParameters: {
          'rider_lat': lat.toString(),
          'rider_lng': lng.toString(),
        },
      );

      final response = await http.get(
        uri,
        headers: {
          'Authorization': 'Bearer ${auth.token}',
          'Accept': 'application/json',
        },
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() {
          _routeData = data;
          _isLoading = false;
        });
      } else {
        String errMsg = AppStrings.tr(
          'Failed to load route optimization (HTTP {code}).',
          args: {'code': '${response.statusCode}'},
        );
        try {
          final b = jsonDecode(response.body);
          if (b is Map && b['detail'] != null) errMsg = b['detail'].toString();
        } catch (_) {}
        setState(() {
          _error = errMsg;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = AppStrings.tr('Network error: {err}', args: {'err': '$e'});
        _isLoading = false;
      });
    }
  }

  Future<void> _acceptPool() async {
    final auth = context.read<AuthProvider>();
    if (auth.token == null) return;

    setState(() => _isAccepting = true);

    try {
      final uri = Uri.parse('$kApiBaseUrl/pools/${widget.poolId}/accept');
      final response = await http.post(
        uri,
        headers: {
          'Authorization': 'Bearer ${auth.token}',
          'Accept': 'application/json',
        },
      );

      if (!mounted) return;

      if (response.statusCode == 200 || response.statusCode == 201) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.trAsync('Pool Accepted! Trips created for each member.'),
            ),
            backgroundColor: kRiderGreen,
          ),
        );
        Navigator.of(context).pop(true);
      } else {
        String msg = context.trAsync('Could not accept pool.');
        try {
          final b = jsonDecode(response.body);
          if (b is Map && b['detail'] != null) msg = b['detail'].toString();
        } catch (_) {}
        setState(() => _isAccepting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), backgroundColor: Colors.red.shade700),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isAccepting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.trAsync('Network error: {err}', args: {'err': '$e'}),
          ),
          backgroundColor: Colors.red.shade700,
        ),
      );
    }
  }

  Future<void> _openDeliveryProofDialog(double totalDistanceKm) async {
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
          poolId: widget.poolId,
          imageBytes: bytes,
          sourceFilename: filename,
          distanceKm: totalDistanceKm > 0 ? totalDistanceKm : null,
        ),
      ),
    );

    if (result == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.trAsync(
              'Pool marked as delivered! Tap Generate Payment QR to collect payment.',
            ),
          ),
          backgroundColor: kRiderGreen,
        ),
      );
      await _loadData();
    }
  }

  Future<void> _openPoolPaymentQr() async {
    final auth = context.read<AuthProvider>();
    if (auth.token == null) return;
    final paid = await showPoolPaymentQrDialog(
      context,
      token: auth.token!,
      poolId: widget.poolId,
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
      await _loadData();
    }
  }

  Future<void> _showVerifyOtpDialog(Map<String, dynamic> stop) async {
    final farmerName =
        (stop['farmer_name'] ?? context.trAsync('Farmer')).toString();
    final produceRequestId = (stop['produce_request_id'] ?? '').toString();
    if (produceRequestId.isEmpty) return;

    final auth = context.read<AuthProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final otpController = TextEditingController();
    String? dialogError;
    bool isVerifying = false;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              const Icon(Icons.verified_user_outlined, color: kRiderGreen),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  ctx.tr('Verify Pickup'),
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                ctx.tr(
                  'Enter the 4-digit pickup OTP provided by {name} to confirm produce pickup.',
                  args: {'name': farmerName},
                ),
                style: const TextStyle(fontSize: 13, color: Colors.black87),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: otpController,
                keyboardType: TextInputType.number,
                maxLength: 4,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 26, letterSpacing: 8, fontWeight: FontWeight.bold),
                decoration: InputDecoration(
                  counterText: '',
                  hintText: '••••',
                  hintStyle: const TextStyle(letterSpacing: 8),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  errorText: dialogError,
                  prefixIcon: const Icon(Icons.lock_outline, color: kRiderGreen),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: isVerifying ? null : () => Navigator.pop(dialogCtx),
              child: Text(ctx.tr('Cancel')),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: kRiderGreen),
              onPressed: isVerifying
                  ? null
                  : () async {
                      final code = otpController.text.trim();
                      if (code.length != 4 || !RegExp(r'^\d{4}$').hasMatch(code)) {
                        setDialogState(
                          () => dialogError = AppStrings.tr(
                            'Enter a 4-digit numeric OTP.',
                          ),
                        );
                        return;
                      }

                      setDialogState(() {
                        isVerifying = true;
                        dialogError = null;
                      });

                      try {
                        final uri = Uri.parse('$kApiBaseUrl/pools/${widget.poolId}/verify-farmer-otp');
                        final resp = await http.post(
                          uri,
                          headers: {
                            'Authorization': 'Bearer ${auth.token}',
                            'Content-Type': 'application/json',
                            'Accept': 'application/json',
                          },
                          body: jsonEncode({
                            'produce_request_id': produceRequestId,
                            'otp': code,
                          }),
                        );

                        if (resp.statusCode == 200) {
                          if (dialogCtx.mounted) Navigator.pop(dialogCtx);
                          if (!mounted) return;
                          setState(() {
                            stop['status'] = 'PICKED_UP';
                          });
                          messenger.showSnackBar(
                            SnackBar(
                              content: Text(
                                AppStrings.tr(
                                  'Pickup verified for {name}!',
                                  args: {'name': farmerName},
                                ),
                              ),
                              backgroundColor: kRiderGreen,
                            ),
                          );
                          _loadData();
                        } else {
                          String msg = AppStrings.tr('Invalid OTP.');
                          try {
                            final data = jsonDecode(resp.body);
                            if (data is Map && data['detail'] != null) {
                              msg = data['detail'].toString();
                            }
                          } catch (_) {}
                          setDialogState(() {
                            isVerifying = false;
                            dialogError = msg;
                          });
                        }
                      } catch (e) {
                        setDialogState(() {
                          isVerifying = false;
                          dialogError = AppStrings.tr(
                            'Network error: {err}',
                            args: {'err': '$e'},
                          );
                        });
                      }
                    },
              child: isVerifying
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : Text(ctx.tr('Verify')),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _callPhone(String? phone) async {
    if (phone == null || phone.trim().isEmpty) return;
    final cleaned = phone.replaceAll(RegExp(r'[^\d+]'), '');
    if (cleaned.isEmpty) return;
    final uri = Uri(scheme: 'tel', path: cleaned);
    try {
      await launchUrl(uri);
    } catch (_) {}
  }

  Future<void> _openMaps(double? lat, double? lng, String fallbackQuery) async {
    String q;
    if (lat != null && lng != null) {
      q = '$lat,$lng';
    } else {
      q = fallbackQuery.trim();
    }
    if (q.isEmpty) return;
    final uri = Uri.parse('https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent(q)}');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9FBF9),
      appBar: AppBar(
        title: Text(
          context.tr(
            widget.isActiveTrip ? 'Active Pool Route' : 'Pool Details & Route',
          ),
        ),
        backgroundColor: kRiderGreen,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: context.tr('Refresh Route'),
            onPressed: _isLoading ? null : _loadData,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(color: kRiderGreen),
            const SizedBox(height: 16),
            Text(
              context.tr('Computing optimal road pickup sequence…'),
              style: const TextStyle(color: Colors.black54, fontSize: 14),
            ),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 56, color: Colors.red.shade400),
              const SizedBox(height: 16),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 15, color: Colors.black87),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _loadData,
                icon: const Icon(Icons.refresh),
                label: Text(context.tr('Retry')),
                style: FilledButton.styleFrom(backgroundColor: kRiderGreen),
              ),
            ],
          ),
        ),
      );
    }

    final data = _routeData!;
    final List<dynamic> stops = (data['ordered_stops'] as List<dynamic>?) ?? const [];
    final List<dynamic> rawGeom = (data['route_geometry'] as List<dynamic>?) ?? const [];

    final List<LatLng> polylinePoints = rawGeom.map((pt) {
      final list = pt as List<dynamic>;
      return LatLng((list[0] as num).toDouble(), (list[1] as num).toDouble());
    }).toList();

    final riderStart = data['rider_start'] as Map<String, dynamic>?;
    final dest = data['destination'] as Map<String, dynamic>?;

    final riderLat = (riderStart?['lat'] as num?)?.toDouble() ?? 12.9141;
    final riderLng = (riderStart?['lng'] as num?)?.toDouble() ?? 74.8560;

    final destLat = (dest?['lat'] as num?)?.toDouble() ?? 12.9141;
    final destLng = (dest?['lng'] as num?)?.toDouble() ?? 74.8560;
    final destName =
        (dest?['name'] ?? context.tr('Mandi Destination')).toString();

    final double totalDistanceKm = ((data['total_distance_km'] ?? 0) as num).toDouble();
    final double durationMins = ((data['estimated_duration_minutes'] ?? 0) as num).toDouble();
    final double totalWeightKg = ((data['total_weight_kg'] ?? 0) as num).toDouble();
    final String cropType =
        (data['crop_type'] ?? context.tr('Produce')).toString();
    final String? warning = data['warning'] as String?;

    // Rider registered capacity validation
    final riderCapKg = _riderCapacityKg;
    final bool exceedsCapacity = riderCapKg != null && riderCapKg > 0 && totalWeightKg > riderCapKg;

    final String poolStatus = (data['pool_status'] ?? 'OPEN').toString().toUpperCase();
    final String paymentStatus = (data['payment_status'] ?? '').toString().toUpperCase();
    final bool isPoolPaid = paymentStatus == 'PAID';
    final double? totalCropValue = (data['total_crop_value'] as num?)?.toDouble();
    final double? totalRiderFare = (data['total_rider_fare'] as num?)?.toDouble();
    final double? totalPlatformFee = (data['total_platform_fee'] as num?)?.toDouble();
    final double? totalNetPayout = (data['total_net_payout'] as num?)?.toDouble();
    final double? ratePerKg = (data['rate_per_kg'] as num?)?.toDouble();
    final String rateSource = (data['rate_source'] ?? '').toString();
    final String? paymentRef = data['payment_reference']?.toString();
    final bool isPoolDelivered = poolStatus == 'COMPLETED' ||
        poolStatus == 'DELIVERED' ||
        data['all_delivered'] == true ||
        (stops.isNotEmpty &&
            stops.every((s) {
              final st = ((s as Map<String, dynamic>)['status'] ?? '').toString().toUpperCase();
              return st == 'DELIVERED' || st == 'COMPLETED';
            }));
    final int pickedUpCount = stops.where((s) {
      final st = ((s as Map<String, dynamic>)['status'] ?? '').toString().toUpperCase();
      return st == 'PICKED_UP' || st == 'IN_TRANSIT' || st == 'DELIVERED' || st == 'COMPLETED';
    }).length;
    final bool allPickedUp = data['all_picked_up'] == true ||
        (stops.isNotEmpty && pickedUpCount == stops.length);

    // Build Map Markers
    final List<Marker> markers = [];

    // 1. Rider Start Marker
    markers.add(
      Marker(
        point: LatLng(riderLat, riderLng),
        width: 44,
        height: 44,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.blue.shade700,
            shape: BoxShape.circle,
            boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2))],
          ),
          child: const Icon(Icons.navigation, color: Colors.white, size: 22),
        ),
      ),
    );

    // 2. Farmer Pickup Markers (Numbered badges)
    for (final s in stops) {
      final map = s as Map<String, dynamic>;
      final lat = (map['lat'] as num?)?.toDouble();
      final lng = (map['lng'] as num?)?.toDouble();
      final seq = map['sequence'] ?? '';
      if (lat != null && lng != null) {
        markers.add(
          Marker(
            point: LatLng(lat, lng),
            width: 36,
            height: 36,
            child: Container(
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: kRiderGreen,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2))],
              ),
              child: Text(
                '$seq',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ),
          ),
        );
      }
    }

    // 3. Dropoff Mandi Marker
    markers.add(
      Marker(
        point: LatLng(destLat, destLng),
        width: 44,
        height: 44,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.red.shade700,
            shape: BoxShape.circle,
            boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2))],
          ),
          child: const Icon(Icons.storefront, color: Colors.white, size: 24),
        ),
      ),
    );

    // Calculate map initial center
    final LatLng centerPoint = polylinePoints.isNotEmpty
        ? polylinePoints[polylinePoints.length ~/ 2]
        : LatLng(riderLat, riderLng);

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Top Map View
                SizedBox(
                  height: 280,
                  child: Stack(
                    children: [
                      FlutterMap(
                        mapController: _mapController,
                        options: MapOptions(
                          initialCenter: centerPoint,
                          initialZoom: 12.0,
                        ),
                        children: [
                          TileLayer(
                            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                            userAgentPackageName: 'com.kisanrider.app',
                          ),
                          if (polylinePoints.isNotEmpty)
                            PolylineLayer(
                              polylines: [
                                Polyline(
                                  points: polylinePoints,
                                  strokeWidth: 4.5,
                                  color: kRiderGreen,
                                ),
                              ],
                            ),
                          MarkerLayer(markers: markers),
                        ],
                      ),
                      // Map Legend badge
                      Positioned(
                        top: 10,
                        left: 10,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.92),
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.route, size: 16, color: kRiderGreen),
                              const SizedBox(width: 6),
                              Text(
                                context.tr('Road Network Route'),
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.black87),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Metrics Strip
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  color: Colors.white,
                  child: Row(
                    children: [
                      Expanded(
                        child: _MetricItem(
                          icon: Icons.alt_route,
                          title: context.tr('Distance'),
                          value: '${totalDistanceKm.toStringAsFixed(1)} ${context.tr('km')}',
                        ),
                      ),
                      Container(height: 36, width: 1, color: Colors.grey.shade200),
                      Expanded(
                        child: _MetricItem(
                          icon: Icons.timer_outlined,
                          title: context.tr('Est. Time'),
                          value: durationMins > 0 ? '${durationMins.toStringAsFixed(0)} ${context.tr('mins')}' : '—',
                        ),
                      ),
                      Container(height: 36, width: 1, color: Colors.grey.shade200),
                      Expanded(
                        child: _MetricItem(
                          icon: Icons.scale_outlined,
                          title: context.tr('Combined'),
                          value: '${totalWeightKg.toStringAsFixed(0)} ${context.tr('kg')}',
                        ),
                      ),
                    ],
                  ),
                ),

                if (warning != null && warning.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.amber.shade50,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.amber.shade300),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.info_outline, size: 20, color: Colors.amber.shade800),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            warning,
                            style: TextStyle(fontSize: 12, color: Colors.amber.shade900),
                          ),
                        ),
                      ],
                    ),
                  ),

                // Capacity Alert if exceeds Rider payload
                if (exceedsCapacity)
                  Container(
                    margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.red.shade300),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.warning_amber_rounded, size: 24, color: Colors.red.shade800),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            context.tr(
                              'Capacity Alert: Pool total ({total} kg) exceeds your registered vehicle payload capacity ({cap} kg). Acceptance disabled.',
                              args: {
                                'total': totalWeightKg.toStringAsFixed(0),
                                'cap': riderCapKg.toStringAsFixed(0),
                              },
                            ),
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.red.shade900),
                          ),
                        ),
                      ],
                    ),
                  ),

                // Common Dropoff Card
                Container(
                  margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey.shade200),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.red.shade50,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(Icons.storefront, color: Colors.red.shade700, size: 24),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              context.tr('COMMON DROPOFF MARKET'),
                              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.black54, letterSpacing: 0.5),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              destName,
                              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.black87),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: context.tr('Navigate'),
                        icon: const Icon(Icons.directions, color: kRiderGreen),
                        onPressed: () => _openMaps(destLat, destLng, destName),
                      ),
                    ],
                  ),
                ),

                if (isPoolDelivered && totalCropValue != null)
                  Container(
                    margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isPoolPaid ? const Color(0xFFA5D6A7) : Colors.amber.shade300,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              isPoolPaid ? Icons.verified_rounded : Icons.qr_code_2_rounded,
                              size: 18,
                              color: isPoolPaid ? const Color(0xFF166534) : Colors.amber.shade900,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                context.tr('POOL PAYMENT BREAKDOWN'),
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF6B7280),
                                  letterSpacing: 0.8,
                                ),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: isPoolPaid ? const Color(0xFFE8F5E9) : Colors.amber.shade50,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: isPoolPaid ? kRiderGreen : Colors.amber.shade400,
                                ),
                              ),
                              child: Text(
                                context.trStatus(isPoolPaid ? 'PAID' : 'PENDING QR'),
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: isPoolPaid ? const Color(0xFF166534) : Colors.amber.shade900,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        _PoolPayRow(label: context.tr('Total Crop Sale'), value: formatIndianRupees(totalCropValue), bold: true),
                        if (totalRiderFare != null)
                          _PoolPayRow(label: context.tr('Rider Transport Fare'), value: formatIndianRupees(totalRiderFare), color: kRiderGreen, bold: true),
                        if (totalPlatformFee != null)
                          _PoolPayRow(label: context.tr('Platform Fee (2%)'), value: '- ${formatIndianRupees(totalPlatformFee)}', color: Colors.red.shade700),
                        if (totalNetPayout != null) ...[
                          const Divider(height: 12),
                          _PoolPayRow(label: context.tr('Farmers Net Payout'), value: formatIndianRupees(totalNetPayout), color: const Color(0xFF166534), bold: true),
                        ],
                        if (ratePerKg != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              '${context.tr('Rate: ₹{rate}/kg ({source})', args: {
                                'rate': ratePerKg.toStringAsFixed(0),
                                'source': rateSource == 'mandi_api'
                                    ? context.tr('Mandi API Rate')
                                    : context.tr('Standard ₹50/kg Fallback'),
                              })}${paymentRef != null ? ' · ${context.tr('Ref: {ref}', args: {'ref': paymentRef})}' : ''}',
                              style: const TextStyle(fontSize: 11, color: Colors.black54),
                            ),
                          ),
                      ],
                    ),
                  ),

                // Ordered Pickup Sequence Section
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                  child: Row(
                    children: [
                      const Icon(Icons.format_list_numbered, size: 20, color: kRiderGreen),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          context.tr(
                            'Optimized Pickup Sequence ({count} Farmers)',
                            args: {'count': '${stops.length}'},
                          ),
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87),
                        ),
                      ),
                    ],
                  ),
                ),

                ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  itemCount: stops.length,
                  itemBuilder: (context, idx) {
                    final stop = stops[idx] as Map<String, dynamic>;
                    return _FarmerStopCard(
                      stop: stop,
                      cropType: cropType,
                      isActiveTrip: widget.isActiveTrip,
                      onVerifyOtp: _showVerifyOtpDialog,
                      onCall: (phone) => _callPhone(phone),
                      onNavigate: (lat, lng, query) => _openMaps(lat, lng, query),
                    );
                  },
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),

        // Bottom Action Bar (Accept Pool)
        if (!widget.isActiveTrip)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 8, offset: Offset(0, -2))],
            ),
            child: SafeArea(
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: (_isAccepting || exceedsCapacity) ? null : _acceptPool,
                  icon: _isAccepting
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.check_circle_outline),
                  label: Text(
                    exceedsCapacity
                        ? context.tr('Exceeds Vehicle Capacity')
                        : context.tr(
                            _isAccepting ? 'Accepting Pool…' : 'Accept Freight Pool',
                          ),
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: kRiderGreen,
                    disabledBackgroundColor: Colors.grey.shade400,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ),
          )
        else
          Container(
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(
              color: Colors.white,
              boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 8, offset: Offset(0, -2))],
            ),
            child: SafeArea(
              child: isPoolDelivered
                  ? (isPoolPaid
                      ? Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          decoration: BoxDecoration(
                            color: const Color(0xFFE8F5E9),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFFA5D6A7)),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.verified_outlined, color: Color(0xFF166534), size: 22),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  paymentRef != null
                                      ? context.tr(
                                          'Pool Delivered & Paid ({ref})',
                                          args: {'ref': paymentRef},
                                        )
                                      : context.tr('Pool Delivered — Payment Done'),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: Color(0xFF166534),
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14.5,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        )
                      : SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: _openPoolPaymentQr,
                            icon: const Icon(Icons.qr_code_2_rounded, size: 22),
                            label: Text(
                              context.tr('Generate Payment QR'),
                              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                            ),
                            style: FilledButton.styleFrom(
                              backgroundColor: kRiderGreen,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                          ),
                        ))
                  : SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: allPickedUp
                            ? () => _openDeliveryProofDialog(totalDistanceKm)
                            : null,
                        icon: const Icon(Icons.check_circle_outline),
                        label: Text(
                          allPickedUp
                              ? context.tr('✅ Mark as Delivered / Unloaded')
                              : context.tr(
                                  'Verify Pickups ({done}/{total}) to Deliver',
                                  args: {
                                    'done': '$pickedUpCount',
                                    'total': '${stops.length}',
                                  },
                                ),
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor: kRiderGreen,
                          disabledBackgroundColor: Colors.grey.shade300,
                          disabledForegroundColor: Colors.grey.shade700,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ),
            ),
          ),
      ],
    );
  }
}

class _MetricItem extends StatelessWidget {
  const _MetricItem({
    required this.icon,
    required this.title,
    required this.value,
  });

  final IconData icon;
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, size: 20, color: kRiderGreen),
        const SizedBox(height: 4),
        Text(title, style: const TextStyle(fontSize: 11, color: Colors.black54)),
        const SizedBox(height: 2),
        Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.black87)),
      ],
    );
  }
}

class _PoolPayRow extends StatelessWidget {
  const _PoolPayRow({
    required this.label,
    required this.value,
    this.color,
    this.bold = false,
  });

  final String label;
  final String value;
  final Color? color;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: bold ? FontWeight.bold : FontWeight.w600,
              color: color ?? Colors.black87,
            ),
          ),
        ],
      ),
    );
  }
}

class _FarmerStopCard extends StatelessWidget {
  const _FarmerStopCard({
    required this.stop,
    required this.cropType,
    this.isActiveTrip = false,
    this.onVerifyOtp,
    required this.onCall,
    required this.onNavigate,
  });

  final Map<String, dynamic> stop;
  final String cropType;
  final bool isActiveTrip;
  final void Function(Map<String, dynamic>)? onVerifyOtp;
  final void Function(String?) onCall;
  final void Function(double?, double?, String) onNavigate;

  @override
  Widget build(BuildContext context) {
    final seq = stop['sequence'] ?? 1;
    final farmerName = (stop['farmer_name'] ?? context.tr('Farmer')).toString();
    final weight = ((stop['weight_kg'] ?? 0) as num).toDouble();
    final address =
        (stop['pickup_address'] ?? context.tr('Farm Gate')).toString();
    final landmark = (stop['pickup_landmark'] ?? '').toString();
    final lat = (stop['lat'] as num?)?.toDouble();
    final lng = (stop['lng'] as num?)?.toDouble();
    final requestedPickup = stop['requested_pickup_at']?.toString();
    final bool hasCoords = stop['has_coordinates'] == true;

    return Card(
      elevation: 1,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor: kRiderGreen,
                  child: Text('$seq', style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    farmerName,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.black87),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: kRiderGreen.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${weight.toStringAsFixed(0)} ${context.tr('kg')}',
                    style: const TextStyle(color: kRiderGreen, fontWeight: FontWeight.bold, fontSize: 12),
                  ),
                ),
              ],
            ),
            const Divider(height: 20),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.location_on_outlined, size: 18, color: Colors.black54),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(address, style: const TextStyle(fontSize: 13, color: Colors.black87)),
                      if (landmark.isNotEmpty)
                        Text(
                          context.tr(
                            'Landmark: {landmark}',
                            args: {'landmark': landmark},
                          ),
                          style: const TextStyle(fontSize: 12, color: Colors.black54),
                        ),
                      if (hasCoords && lat != null && lng != null)
                        Text(
                          context.tr(
                            'Coords: {lat}, {lng}',
                            args: {
                              'lat': lat.toStringAsFixed(4),
                              'lng': lng.toStringAsFixed(4),
                            },
                          ),
                          style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                        ),
                      if (!hasCoords)
                        Text(
                          context.tr(
                            'Location: Coordinates missing (Address provided)',
                          ),
                          style: TextStyle(fontSize: 11, color: Colors.amber.shade900, fontWeight: FontWeight.bold),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: context.tr('Navigate'),
                  icon: const Icon(Icons.directions, color: Colors.blue),
                  onPressed: () => onNavigate(lat, lng, address),
                ),
              ],
            ),
            if (requestedPickup != null && requestedPickup.isNotEmpty) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  const Icon(Icons.schedule, size: 16, color: Colors.black54),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      context.tr(
                        'Requested: {time}',
                        args: {'time': requestedPickup},
                      ),
                      style: const TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                  ),
                ],
              ),
            ],
            if (isActiveTrip) ...[
              const Divider(height: 20),
              Builder(
                builder: (context) {
                  final status = (stop['status'] ?? 'ACCEPTED').toString().toUpperCase();
                  final bool isDelivered = status == 'DELIVERED' || status == 'COMPLETED';
                  final bool isPickedUp = status == 'PICKED_UP' || isDelivered;
                  return Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: isPickedUp ? Colors.green.shade50 : Colors.amber.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: isPickedUp ? Colors.green.shade300 : Colors.amber.shade300,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              isPickedUp ? Icons.check_circle : Icons.pending_outlined,
                              size: 14,
                              color: isPickedUp ? Colors.green.shade700 : Colors.amber.shade800,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              context.tr(
                                isDelivered
                                    ? 'Delivered'
                                    : (isPickedUp ? 'Picked Up' : 'Pending Pickup'),
                              ),
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: isPickedUp ? Colors.green.shade800 : Colors.amber.shade900,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (!isPickedUp)
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: kRiderGreen,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            visualDensity: VisualDensity.compact,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          icon: const Icon(Icons.pin, size: 16),
                          label: Text(
                            context.tr('Verify OTP'),
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                          onPressed: onVerifyOtp != null ? () => onVerifyOtp!(stop) : null,
                        ),
                    ],
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}
