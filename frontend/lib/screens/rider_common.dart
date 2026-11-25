import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

/// Base URL of the FastAPI backend.
String get kApiBaseUrl {
  if (kIsWeb) return 'http://localhost:8000';
  return 'http://10.28.1.142:8000';
}

/// Search radius for the nearby feed.
const double kSearchRadiusKm = 50.0;

/// Brand green used across the rider UI.
const Color kRiderGreen = Color(0xFF2E7D32);

/// Notifier incremented whenever a QR payment succeeds so Earnings and Active
/// tabs refresh cleanly without stale cache.
final ValueNotifier<int> kPaymentEventsNotifier = ValueNotifier<int>(0);

// ---------------------------------------------------------------------------
// Google Maps helper
// ---------------------------------------------------------------------------

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

enum OtpSubmitResult { success, invalidOtp, otherError }

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

/// One PENDING produce request surfaced by `GET /produce-requests/nearby`.
class AvailableRequest {
  AvailableRequest({
    required this.id,
    required this.cropType,
    required this.weightKg,
    required this.latitude,
    required this.longitude,
    required this.distanceKm,
    required this.status,
    required this.createdAt,
    this.requestedPickupAt,
    this.dropoffLocation,
    this.pickupAddress,
    this.pickupLandmark,
    required this.pickupWindowStart,
    required this.pickupWindowEnd,
  });

  factory AvailableRequest.fromJson(Map<String, dynamic> json) {
    DateTime parsedCreatedAt;
    final rawCreated = json['created_at'];
    if (rawCreated is String) {
      parsedCreatedAt = DateTime.tryParse(rawCreated) ??
          DateTime.fromMillisecondsSinceEpoch(0);
    } else {
      parsedCreatedAt = DateTime.fromMillisecondsSinceEpoch(0);
    }

    DateTime? parsedRequestedPickupAt;
    final rawRequestedPickup = json['requested_pickup_at'];
    if (rawRequestedPickup is String) {
      parsedRequestedPickupAt = DateTime.tryParse(rawRequestedPickup);
    }

    DateTime? parsedWindowStart;
    final rawWinStart = json['pickup_window_start'];
    if (rawWinStart is String) {
      parsedWindowStart = DateTime.tryParse(rawWinStart);
    }

    DateTime? parsedWindowEnd;
    final rawWinEnd = json['pickup_window_end'];
    if (rawWinEnd is String) {
      parsedWindowEnd = DateTime.tryParse(rawWinEnd);
    }

    return AvailableRequest(
      id: (json['id'] ?? '').toString(),
      cropType: (json['crop_type'] ?? '') as String,
      weightKg: ((json['weight_kg'] ?? 0) as num).toDouble(),
      latitude: ((json['latitude'] ?? 0) as num).toDouble(),
      longitude: ((json['longitude'] ?? 0) as num).toDouble(),
      distanceKm: ((json['distance_km'] ?? 0) as num).toDouble(),
      status: (json['status'] ?? 'PENDING') as String,
      createdAt: parsedCreatedAt,
      requestedPickupAt: parsedRequestedPickupAt,
      dropoffLocation: json['dropoff_location'] as String?,
      pickupAddress: (json['pickup_address'] as String?)?.trim(),
      pickupLandmark: (json['pickup_landmark'] as String?)?.trim(),
      pickupWindowStart: parsedWindowStart ?? parsedRequestedPickupAt ?? parsedCreatedAt,
      pickupWindowEnd: parsedWindowEnd ?? (parsedRequestedPickupAt != null ? parsedRequestedPickupAt.add(const Duration(hours: 2)) : parsedCreatedAt.add(const Duration(hours: 2))),
    );
  }

  final String id;
  final String cropType;
  final double weightKg;
  final double latitude;
  final double longitude;
  final double distanceKm;
  final String status;
  final DateTime createdAt;
  final DateTime? requestedPickupAt;
  final String? dropoffLocation;
  final String? pickupAddress;
  final String? pickupLandmark;
  final DateTime pickupWindowStart;
  final DateTime pickupWindowEnd;

  String get displayRequestedPickup {
    if (requestedPickupAt == null) return '';
    final local = requestedPickupAt!.toLocal();
    final months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    final day = local.day.toString().padLeft(2, '0');
    final month = months[local.month - 1];
    final year = local.year;
    final hour = local.hour > 12 ? local.hour - 12 : (local.hour == 0 ? 12 : local.hour);
    final ampm = local.hour >= 12 ? 'PM' : 'AM';
    final minute = local.minute.toString().padLeft(2, '0');
    return '$day $month $year — $hour:$minute $ampm';
  }

  String get displayPickup {
    if (pickupAddress != null && pickupAddress!.isNotEmpty) {
      return pickupAddress!;
    }
    if (pickupLandmark != null && pickupLandmark!.isNotEmpty) {
      return pickupLandmark!;
    }
    return '${latitude.toStringAsFixed(4)}, ${longitude.toStringAsFixed(4)}';
  }

  String get mapsQuery {
    if (pickupAddress != null && pickupAddress!.isNotEmpty) {
      return pickupAddress!;
    }
    return '$latitude,$longitude';
  }

  bool get hasPickupAddress =>
      (pickupAddress != null && pickupAddress!.isNotEmpty) ||
      (pickupLandmark != null && pickupLandmark!.isNotEmpty);
}

/// One of the rider's active trips, from `GET /trips/active`.
class ActiveTrip {
  ActiveTrip({
    required this.id,
    required this.produceRequestId,
    required this.status,
    required this.cropType,
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

  String get displayPickup {
    if (pickupAddress != null && pickupAddress!.trim().isNotEmpty) {
      return pickupAddress!.trim();
    }
    return '${latitude.toStringAsFixed(4)}, ${longitude.toStringAsFixed(4)}';
  }

  String get mapsQuery {
    if (pickupAddress != null && pickupAddress!.trim().isNotEmpty) {
      return pickupAddress!.trim();
    }
    return '$latitude,$longitude';
  }
}

// ---------------------------------------------------------------------------
// Shared widgets
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Shared Delivery Proof Upload & Dialog (used by both Individual & Pool flows)
// ---------------------------------------------------------------------------

const Duration kDeliveryUploadTimeout = Duration(seconds: 15);

class DeliveryResult {
  const DeliveryResult.success()
      : success = true,
        errorMessage = null;

  const DeliveryResult.failure(this.errorMessage) : success = false;

  final bool success;
  final String? errorMessage;
}

String _mimeSubtypeFromFilename(String filename) {
  final lower = filename.toLowerCase();
  final dot = lower.lastIndexOf('.');
  if (dot == -1 || dot == lower.length - 1) return 'jpeg';

  final ext = lower.substring(dot + 1);
  switch (ext) {
    case 'jpg':
    case 'jpeg':
      return 'jpeg';
    case 'png':
      return 'png';
    case 'webp':
      return 'webp';
    default:
      return 'jpeg';
  }
}

String _extractHttpErrorDetail(http.Response response, String fallback) {
  try {
    final decoded = jsonDecode(response.body);
    if (decoded is Map && decoded['detail'] != null) {
      final detail = decoded['detail'].toString();
      return detail.length > 300 ? '${detail.substring(0, 300)}…' : detail;
    }
  } catch (_) {}
  return fallback;
}

/// Uploads a proof-of-delivery photo to `POST /uploads/delivery-photo`
/// and returns its `image_url`, or an `errorMessage` on failure.
Future<({String? imageUrl, String? errorMessage})> uploadDeliveryProofPhoto({
  required String token,
  required Uint8List imageBytes,
  required String sourceFilename,
  Duration timeout = kDeliveryUploadTimeout,
}) async {
  try {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$kApiBaseUrl/uploads/delivery-photo'),
    );
    request.headers['Authorization'] = 'Bearer $token';
    request.headers['Accept'] = 'application/json';

    final extension = _mimeSubtypeFromFilename(sourceFilename);

    request.files.add(
      http.MultipartFile.fromBytes(
        'file',
        imageBytes,
        filename: 'proof.$extension',
        contentType: MediaType('image', extension),
      ),
    );

    final streamed = await request.send().timeout(timeout);
    final uploadResp = await http.Response.fromStream(streamed).timeout(timeout);

    if (uploadResp.statusCode != 200 && uploadResp.statusCode != 201) {
      return (
        imageUrl: null,
        errorMessage: _extractHttpErrorDetail(
          uploadResp,
          'Photo upload failed (HTTP ${uploadResp.statusCode}).',
        ),
      );
    }

    String? imageUrl;
    try {
      final decoded = jsonDecode(uploadResp.body);
      if (decoded is Map && decoded['image_url'] != null) {
        imageUrl = decoded['image_url'].toString();
      }
    } catch (_) {}

    if (imageUrl == null || imageUrl.trim().isEmpty) {
      return (
        imageUrl: null,
        errorMessage: 'Server did not return a valid photo URL.',
      );
    }

    return (imageUrl: imageUrl, errorMessage: null);
  } on TimeoutException catch (e) {
    debugPrint('Upload Error (timeout): $e');
    return (
      imageUrl: null,
      errorMessage: 'Connection timed out. Please check backend server.',
    );
  } catch (e) {
    debugPrint('Upload Error: $e');
    return (imageUrl: null, errorMessage: 'Error: $e');
  }
}

/// Uploads delivery proof photo and transitions a pool to delivered/completed.
Future<DeliveryResult> deliverPoolWithProof({
  required String token,
  required String poolId,
  required Uint8List imageBytes,
  required String sourceFilename,
  double? distanceKm,
  Duration timeout = kDeliveryUploadTimeout,
}) async {
  final uploaded = await uploadDeliveryProofPhoto(
    token: token,
    imageBytes: imageBytes,
    sourceFilename: sourceFilename,
    timeout: timeout,
  );

  if (uploaded.imageUrl == null) {
    return DeliveryResult.failure(
      uploaded.errorMessage ?? 'Photo upload failed.',
    );
  }

  try {
    final body = <String, dynamic>{
      'delivery_photo_url': uploaded.imageUrl,
    };
    if (distanceKm != null && distanceKm > 0) {
      body['distance_km'] = distanceKm;
    }

    final resp = await http
        .post(
          Uri.parse('$kApiBaseUrl/pools/$poolId/deliver'),
          headers: {
            'Authorization': 'Bearer $token',
            'Accept': 'application/json',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(body),
        )
        .timeout(timeout);

    if (resp.statusCode != 200 && resp.statusCode != 201) {
      return DeliveryResult.failure(
        _extractHttpErrorDetail(
          resp,
          'Could not mark pool delivered (HTTP ${resp.statusCode}).',
        ),
      );
    }

    return const DeliveryResult.success();
  } on TimeoutException catch (e) {
    debugPrint('Pool deliver timeout: $e');
    return const DeliveryResult.failure(
      'Connection timed out. Please check backend server.',
    );
  } catch (e) {
    debugPrint('Pool deliver error: $e');
    return DeliveryResult.failure('Error: $e');
  }
}

class DeliveryProofDialog extends StatefulWidget {
  const DeliveryProofDialog({
    super.key,
    required this.onSubmit,
    this.subtitleText,
  });

  final Future<DeliveryResult> Function(
    Uint8List photoBytes,
    String sourceFilename,
  ) onSubmit;

  final String? subtitleText;

  @override
  State<DeliveryProofDialog> createState() => _DeliveryProofDialogState();
}

class _DeliveryProofDialogState extends State<DeliveryProofDialog> {
  final ImagePicker _picker = ImagePicker();

  XFile? _pickedFile;
  Uint8List? _imageBytes;

  bool _isUploading = false;
  String? _error;

  Future<void> _pick(ImageSource source) async {
    try {
      final picked = await _picker.pickImage(
        source: source,
        maxWidth: 1600,
        imageQuality: 85,
      );
      if (picked == null) return;

      final bytes = await picked.readAsBytes();
      if (!mounted) return;

      setState(() {
        _pickedFile = picked;
        _imageBytes = bytes;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      final hint = kIsWeb
          ? ' (if using Camera, try Gallery instead — browsers often block '
              'camera access on non-HTTPS origins or desktops without a webcam)'
          : '';
      setState(() => _error = 'Could not pick image: $e$hint');
    }
  }

  Future<void> _submit() async {
    final bytes = _imageBytes;
    if (bytes == null || bytes.isEmpty) {
      setState(() => _error = 'Please attach a photo first.');
      return;
    }

    setState(() {
      _isUploading = true;
      _error = null;
    });

    final filename = _pickedFile?.name ?? 'proof.jpg';

    try {
      final result = await widget.onSubmit(bytes, filename);

      if (!mounted) return;

      if (result.success) {
        Navigator.of(context).pop(true);
        return;
      }

      setState(() {
        _error = result.errorMessage ??
            'Could not complete delivery. Please try again.';
      });
    } catch (e) {
      debugPrint('Dialog submit error: $e');
      if (!mounted) return;
      setState(() => _error = 'Error: $e');
    } finally {
      if (mounted) {
        setState(() => _isUploading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('Upload Delivery Proof'),
      content: SizedBox(
        width: 320,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.subtitleText ??
                    'Take a photo of the delivered crates at the mandi. '
                        'This is required before the trip can be completed.',
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 16),

              if (_imageBytes == null)
                Container(
                  height: 180,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.image_outlined,
                      size: 48,
                      color: Colors.black26,
                    ),
                  ),
                )
              else
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.memory(
                    _imageBytes!,
                    height: 200,
                    width: 320,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    errorBuilder: (_, _, _) => Container(
                      height: 200,
                      width: 320,
                      color: Colors.grey.shade200,
                      alignment: Alignment.center,
                      child: const Icon(
                        Icons.broken_image_outlined,
                        size: 48,
                        color: Colors.black26,
                      ),
                    ),
                  ),
                ),

              const SizedBox(height: 12),

              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _isUploading
                          ? null
                          : () => _pick(ImageSource.camera),
                      icon: const Icon(
                        Icons.camera_alt_outlined,
                        size: 18,
                      ),
                      label: const Text('Camera'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _isUploading
                          ? null
                          : () => _pick(ImageSource.gallery),
                      icon: const Icon(
                        Icons.photo_library_outlined,
                        size: 18,
                      ),
                      label: const Text('Gallery'),
                    ),
                  ),
                ],
              ),

              if (_isUploading) ...[
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'Uploading proof of delivery…',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ],

              if (_error != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer
                        .withValues(alpha: 0.4),
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
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      actions: [
        TextButton(
          onPressed:
              _isUploading ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _isUploading ? null : _submit,
          icon: _isUploading
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
            _isUploading ? 'Uploading…' : 'Upload Proof of Delivery',
          ),
          style: FilledButton.styleFrom(backgroundColor: kRiderGreen),
        ),
      ],
    );
  }
}