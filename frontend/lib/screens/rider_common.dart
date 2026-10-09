import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;   // <-- ADDED
import 'package:url_launcher/url_launcher.dart';

/// Base URL of the FastAPI backend.
String get kApiBaseUrl {
  if (kIsWeb) return 'http://localhost:8000';
  return 'http://10.28.1.142:8000';
}

/// Rider's current position.
const double kRiderLat = 13.1362;
const double kRiderLng = 78.1291;
const double kSearchRadiusKm = 50.0;

/// Brand green used across the rider UI.
const Color kRiderGreen = Color(0xFF2E7D32);

// ---------------------------------------------------------------------------
// Google Maps helper
// ---------------------------------------------------------------------------

/// Opens Google Maps in the platform's external app, searching for [query].
///
/// [query] can be either a `"lat,lng"` string or a free-text address — the
/// Maps search endpoint accepts both. Shows a SnackBar if the platform
/// refuses to launch (no Maps app, no browser, etc.).
Future<void> launchMaps(BuildContext context, String query) async {
  final trimmed = query.trim();
  if (trimmed.isEmpty) return;

  final Uri url = Uri.parse(
    'https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent(trimmed)}',
  );

  try {
    final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open Google Maps')),
      );
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open Google Maps')),
      );
    }
  }
}

// ---------------------------------------------------------------------------
// Phone call helper
// ---------------------------------------------------------------------------

/// Opens the platform's phone dialer pre-filled with [phone].
///
/// The number is stripped of everything except digits and a leading `+` so
/// a value like "+91 98765 43210" works without the caller pre-formatting
/// it. Using `Uri(scheme: 'tel', ...)` rather than a raw string is what
/// makes Android and iOS both recognise the intent.
///
/// Silent no-op if [phone] is empty — the call sites already gate on that,
/// but a defensive check costs nothing.
Future<void> launchPhoneCall(BuildContext context, String phone) async {
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
// OTP submission result
// ---------------------------------------------------------------------------

/// Outcome of a POST to the pickup OTP verify endpoint.
///
/// Shared between the Active Trips tab (which owns the network call) and the
/// OTP dialog (which decides what to render based on the result).
enum OtpSubmitResult { success, invalidOtp, otherError }

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

/// One PENDING produce request surfaced by `GET /produce-requests/nearby`.
class AvailableRequest {
  AvailableRequest({
    required this.id,
    required this.cropType,
    required this.crateCount,
    required this.weightKg,
    required this.latitude,
    required this.longitude,
    required this.distanceKm,
    required this.status,
    this.dropoffLocation,
  });

  factory AvailableRequest.fromJson(Map<String, dynamic> json) {
    return AvailableRequest(
      id: (json['id'] ?? '').toString(),
      cropType: (json['crop_type'] ?? '') as String,
      crateCount: ((json['crate_count'] ?? 0) as num).toInt(),
      weightKg: ((json['weight_kg'] ?? 0) as num).toDouble(),
      latitude: ((json['latitude'] ?? 0) as num).toDouble(),
      longitude: ((json['longitude'] ?? 0) as num).toDouble(),
      distanceKm: ((json['distance_km'] ?? 0) as num).toDouble(),
      status: (json['status'] ?? 'PENDING') as String,
      dropoffLocation: json['dropoff_location'] as String?,
    );
  }

  final String id;
  final String cropType;
  final int crateCount;
  final double weightKg;
  final double latitude;
  final double longitude;
  final double distanceKm;
  final String status;
  final String? dropoffLocation;
}

/// One of the rider's active trips, from `GET /trips/active`.
class ActiveTrip {
  ActiveTrip({
    required this.id,
    required this.produceRequestId,
    required this.status,
    required this.cropType,
    required this.crateCount,
    required this.weightKg,
    required this.latitude,
    required this.longitude,
    this.dropoffAddress,
    this.pickupAddress,
    this.dropoffLat,
    this.dropoffLng,
    this.farmerFullName,
    this.farmerPhoneNumber,
    this.riderFullName,
    this.riderPhoneNumber,
    this.vehicleNumber,
    this.vehicleType,
  });

  factory ActiveTrip.fromJson(Map<String, dynamic> json) {
    final hasNewShape = json.containsKey('trip_id') &&
        !json.containsKey('produce_request');

    if (hasNewShape) {
      return ActiveTrip(
        id: (json['trip_id'] ?? '').toString(),
        produceRequestId: (json['produce_request_id'] ?? '').toString(),
        status: (json['status'] ?? '') as String,
        cropType: (json['crop_type'] ?? '') as String,
        crateCount: ((json['crate_count'] ?? 0) as num).toInt(),
        weightKg: ((json['weight_kg'] ?? 0) as num).toDouble(),
        latitude: ((json['latitude'] ?? 0) as num).toDouble(),
        longitude: ((json['longitude'] ?? 0) as num).toDouble(),
        dropoffAddress: json['dropoff_address'] as String?,
        pickupAddress: json['pickup_address'] as String?,
        dropoffLat: (json['dropoff_lat'] as num?)?.toDouble(),
        dropoffLng: (json['dropoff_lng'] as num?)?.toDouble(),
        farmerFullName: json['farmer_full_name'] as String?,
        farmerPhoneNumber: json['farmer_phone_number'] as String?,
        riderFullName: json['rider_full_name'] as String?,
        riderPhoneNumber: json['rider_phone_number'] as String?,
        vehicleNumber: json['vehicle_number'] as String?,
        vehicleType: json['vehicle_type'] as String?,
      );
    }

    final pr = (json['produce_request'] as Map<String, dynamic>?) ?? const {};

    return ActiveTrip(
      id: (json['id'] ?? '').toString(),
      produceRequestId:
          (pr['id'] ?? json['produce_request_id'] ?? '').toString(),
      status: (json['status'] ?? '') as String,
      cropType: (pr['crop_type'] ?? '') as String,
      crateCount: ((pr['crate_count'] ?? 0) as num).toInt(),
      weightKg: ((pr['weight_kg'] ?? 0) as num).toDouble(),
      latitude: ((pr['latitude'] ?? 0) as num).toDouble(),
      longitude: ((pr['longitude'] ?? 0) as num).toDouble(),
      dropoffAddress: pr['dropoff_location'] as String?,
    );
  }

  final String id;
  final String produceRequestId;
  final String status;
  final String cropType;
  final int crateCount;
  final double weightKg;
  final double latitude;
  final double longitude;

  final String? dropoffAddress;
  final String? pickupAddress;

  final double? dropoffLat;
  final double? dropoffLng;

  final String? farmerFullName;
  final String? farmerPhoneNumber;

  final String? riderFullName;
  final String? riderPhoneNumber;

  final String? vehicleNumber;
  final String? vehicleType;

  bool get isAccepted => status == 'ACCEPTED';
  bool get isInTransit => status == 'PICKED_UP' || status == 'IN_TRANSIT';

  bool get hasFarmerContact =>
      farmerPhoneNumber != null && farmerPhoneNumber!.trim().isNotEmpty;
}

// ---------------------------------------------------------------------------
// Shared widgets
// ---------------------------------------------------------------------------

/// One line of info (icon + label). If [onNavigate] is provided, a small
/// "Navigate" button is rendered at the trailing end that opens Google Maps.
class InfoRow extends StatelessWidget {
  const InfoRow({
    super.key,
    required this.icon,
    required this.label,
    this.onNavigate,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onNavigate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
        if (onNavigate != null)
          IconButton(
            icon: const Icon(Icons.navigation_outlined),
            iconSize: 20,
            visualDensity: VisualDensity.compact,
            tooltip: 'Navigate',
            color: theme.colorScheme.primary,
            onPressed: onNavigate,
          ),
      ],
    );
  }
}

/// Small colored chip showing a trip or request status.
class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.status});

  final String status;

  static const Map<String, (Color, Color)> _colors = {
    'PENDING': (Color(0xFFB45309), Color(0x26F59E0B)),
    'ACCEPTED': (Color(0xFF1D4ED8), Color(0x261D4ED8)),
    'PICKED_UP': (Color(0xFF6D28D9), Color(0x266D28D9)),
    'IN_TRANSIT': (Color(0xFF6D28D9), Color(0x266D28D9)),
    'COMPLETED': (Color(0xFF166534), Color(0x2616A34A)),
    'DELIVERED': (Color(0xFF166534), Color(0x2616A34A)),
    'CANCELLED': (Color(0xFF991B1B), Color(0x26DC2626)),
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
        border: Border.all(color: fg),
      ),
      child: Text(
        status.toUpperCase(),
        style: TextStyle(
          color: fg,
          fontWeight: FontWeight.bold,
          fontSize: 12,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// Full-screen error state with a Retry button.
class ErrorView extends StatelessWidget {
  const ErrorView({
    super.key,
    required this.message,
    required this.onRetry,
  });

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
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
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