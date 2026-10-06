import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import 'rider_common.dart';

/// Statuses from which a rider may complete a delivery. The backend rejects
/// the PATCH unless the trip is in one of these — mirrored client-side so
/// the "Mark Delivered" affordance is disabled when it would definitely fail.
const Set<String> _kCompletableTripStatuses = {'PICKED_UP', 'IN_TRANSIT'};

/// Upload + status-PATCH timeout. Long enough to survive a slow 4G handoff,
/// short enough that a hung connection doesn't leave the spinner spinning
/// forever. On expiry, `_uploadProofAndDeliver` returns a specific
/// "Connection timed out" failure that the dialog surfaces verbatim.
const Duration _kUploadTimeout = Duration(seconds: 15);

/// Outcome of a proof-of-delivery upload.
///
/// Distinct from [OtpSubmitResult] because the delivery flow needs to
/// surface the backend's exact rejection reason to the rider (e.g. "Trip
/// must be in PICKED_UP status"), not just a boolean-ish success/failure.
class DeliveryResult {
  const DeliveryResult.success()
      : success = true,
        errorMessage = null;

  const DeliveryResult.failure(this.errorMessage) : success = false;

  final bool success;
  final String? errorMessage;
}

/// Tab 1 of the rider shell: the rider's currently active trips (ACCEPTED or
/// PICKED_UP), with status-transition actions, the pickup OTP dialog, the
/// proof-of-delivery photo upload flow, and a CALL FARMER contact card.
class RiderActiveTab extends StatefulWidget {
  const RiderActiveTab({super.key});

  @override
  State<RiderActiveTab> createState() => _RiderActiveTabState();
}

class _RiderActiveTabState extends State<RiderActiveTab>
    with AutomaticKeepAliveClientMixin {
  final List<ActiveTrip> _trips = [];

  /// IDs of trips with an in-flight status update, so each card can show its
  /// own spinner without blocking the others.
  final Set<String> _updatingTripIds = {};

  bool _isLoading = true;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _fetch());
  }

  Map<String, String> _headers(AuthProvider auth, {bool json = false}) {
    final h = <String, String>{
      'Authorization': 'Bearer ${auth.token}',
      'Accept': 'application/json',
    };
    if (json) h['Content-Type'] = 'application/json';
    return h;
  }

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
        Uri.parse('$kApiBaseUrl/trips/active'),
        headers: _headers(auth),
      );
      if (!mounted) return;

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);

        // The endpoint returns a list, but older versions returned a single
        // object — treat both shapes the same way.
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
              items.map((e) => ActiveTrip.fromJson(e as Map<String, dynamic>)),
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
              'Failed to load active trips (HTTP ${response.statusCode}).';
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

  Future<void> _updateStatus(ActiveTrip trip, String newStatus) async {
    if (_updatingTripIds.contains(trip.id)) return;

    final auth = context.read<AuthProvider>();
    if (auth.token == null) return;

    setState(() => _updatingTripIds.add(trip.id));

    try {
      final response = await http.patch(
        Uri.parse('$kApiBaseUrl/trips/${trip.id}/status'),
        headers: _headers(auth, json: true),
        body: jsonEncode({'status': newStatus}),
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${trip.cropType} → $newStatus'),
            backgroundColor: kRiderGreen,
          ),
        );
        await _fetch();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _extractError(response) ??
                  'Update failed (HTTP ${response.statusCode}).',
            ),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Network error: $e'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    } finally {
      if (mounted) setState(() => _updatingTripIds.remove(trip.id));
    }
  }

  /// Verifies the 4-digit pickup OTP against the backend.
  ///
  /// The verify endpoint targets the ProduceRequest id (not the Trip id).
  /// On a successful verify, the ProduceRequest's status flips to
  /// PICKED_UP on the server, but the Trip status stays ACCEPTED (they're
  /// independent state machines). Since the rider's card reads the Trip
  /// status, we follow up with a PATCH to sync the two.
  ///
  /// If the PATCH fails, we still return success — the OTP was verified,
  /// which is the essential operation.
  Future<OtpSubmitResult> _submitOtp(ActiveTrip trip, String otp) async {
    final auth = context.read<AuthProvider>();
    if (auth.token == null) return OtpSubmitResult.otherError;

    try {
      final verifyResp = await http.post(
        Uri.parse(
          '$kApiBaseUrl/produce-requests/${trip.produceRequestId}/verify-otp',
        ),
        headers: _headers(auth, json: true),
        body: jsonEncode({'otp': otp}),
      );

      if (verifyResp.statusCode == 400) {
        return OtpSubmitResult.invalidOtp;
      }
      if (verifyResp.statusCode != 200) {
        return OtpSubmitResult.otherError;
      }

      // OTP verified — now sync the trip status to PICKED_UP so the card
      // reflects the handoff. Failure here is non-fatal for the OTP flow.
      try {
        await http.patch(
          Uri.parse('$kApiBaseUrl/trips/${trip.id}/status'),
          headers: _headers(auth, json: true),
          body: jsonEncode({'status': 'PICKED_UP'}),
        );
      } catch (_) {
        // Swallowed deliberately — OTP verification already succeeded.
      }

      return OtpSubmitResult.success;
    } catch (_) {
      return OtpSubmitResult.otherError;
    }
  }

  Future<void> _openOtpDialog(ActiveTrip trip) async {
    final success = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _OtpDialog(
        cropName: trip.cropType,
        onSubmit: (otp) => _submitOtp(trip, otp),
      ),
    );

    if (!mounted) return;

    if (success == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('OTP Verified! Order marked as PICKED UP.'),
          backgroundColor: kRiderGreen,
        ),
      );
      await _fetch();
    }
  }

  /// Uploads a proof-of-delivery photo and, on success, transitions the trip
  /// to DELIVERED.
  ///
  /// Two-step flow (matches the backend contract):
  ///   1. POST /uploads/delivery-photo  — multipart file upload, returns
  ///      {image_url}.
  ///   2. PATCH /trips/{id}/status with {"status": "DELIVERED"}.
  Future<DeliveryResult> _uploadProofAndDeliver(
    ActiveTrip trip,
    Uint8List imageBytes,
    String sourceFilename,
  ) async {
    // Pre-condition: trip must be in a completable state.
    if (!_kCompletableTripStatuses.contains(trip.status)) {
      return DeliveryResult.failure(
        'Trip must be in PICKED_UP status before completing '
        '(current: ${trip.status}).',
      );
    }

    final auth = context.read<AuthProvider>();
    if (auth.token == null) {
      return const DeliveryResult.failure('Not signed in.');
    }

    try {
      // ----- Step 1: upload the photo -------------------------------
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$kApiBaseUrl/uploads/delivery-photo'),
      );
      request.headers['Authorization'] = 'Bearer ${auth.token}';
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

      final streamed = await request.send().timeout(_kUploadTimeout);
      final uploadResp =
          await http.Response.fromStream(streamed).timeout(_kUploadTimeout);

      if (uploadResp.statusCode != 200 && uploadResp.statusCode != 201) {
        return DeliveryResult.failure(
          _extractErrorDetail(
            uploadResp,
            'Photo upload failed (HTTP ${uploadResp.statusCode}).',
          ),
        );
      }

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
            'Could not mark trip delivered (HTTP ${patchResp.statusCode}).',
          ),
        );
      }

      return const DeliveryResult.success();
    } on TimeoutException catch (e) {
      debugPrint('Upload Error (timeout): $e');
      // ignore: avoid_print
      print('Upload Error (timeout): $e');
      return const DeliveryResult.failure(
        'Connection timed out. Please check backend server.',
      );
    } catch (e) {
      debugPrint('Upload Error: $e');
      // ignore: avoid_print
      print('Upload Error: $e');
      return DeliveryResult.failure('Error: $e');
    }
  }

  /// Maps a source filename to the MIME subtype the backend expects.
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

  Future<void> _openDeliveryProofDialog(ActiveTrip trip) async {
    if (!_kCompletableTripStatuses.contains(trip.status)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Trip must be PICKED_UP before it can be delivered '
            '(current: ${trip.status}).',
          ),
          backgroundColor: Colors.red.shade700,
        ),
      );
      return;
    }

    final success = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _DeliveryProofDialog(
        onSubmit: (bytes, filename) =>
            _uploadProofAndDeliver(trip, bytes, filename),
      ),
    );

    if (!mounted) return;

    if (success == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Delivery completed with proof!'),
          backgroundColor: kRiderGreen,
        ),
      );
      await _fetch();
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
    super.build(context);

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return ErrorView(message: _error!, onRetry: _fetch);
    }

    if (_trips.isEmpty) {
      return RefreshIndicator(
        onRefresh: _fetch,
        child: ListView(
          children: const [
            SizedBox(height: 160),
            Icon(Icons.delivery_dining_outlined,
                size: 64, color: Colors.black26),
            SizedBox(height: 12),
            Center(
              child: Text(
                'No active trips. Accept a request to get started.',
                style: TextStyle(fontSize: 15, color: Colors.black54),
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _fetch,
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: _trips.length,
        itemBuilder: (context, index) {
          final trip = _trips[index];
          return _ActiveTripCard(
            trip: trip,
            isUpdating: _updatingTripIds.contains(trip.id),
            onUpdateStatus: (newStatus) => _updateStatus(trip, newStatus),
            onEnterOtp: () => _openOtpDialog(trip),
            onMarkDelivered: () => _openDeliveryProofDialog(trip),
          );
        },
      ),
    );
  }
}

class _ActiveTripCard extends StatelessWidget {
  const _ActiveTripCard({
    required this.trip,
    required this.isUpdating,
    required this.onUpdateStatus,
    required this.onEnterOtp,
    required this.onMarkDelivered,
  });

  final ActiveTrip trip;
  final bool isUpdating;
  final void Function(String newStatus) onUpdateStatus;
  final VoidCallback onEnterOtp;
  final VoidCallback onMarkDelivered;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dropoff = trip.dropoffAddress ?? '';

    // Pickup display: prefer the free-text address; fall back to coords.
    final pickupDisplay = (trip.pickupAddress != null &&
            trip.pickupAddress!.trim().isNotEmpty)
        ? trip.pickupAddress!.trim()
        : '${trip.latitude.toStringAsFixed(4)}, '
            '${trip.longitude.toStringAsFixed(4)}';

    return Card(
      elevation: 1,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ----- Header: crop | status ---------------------------------
            Row(
              children: [
                Expanded(
                  child: Text(
                    trip.cropType,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                StatusBadge(status: trip.status),
              ],
            ),
            const SizedBox(height: 12),

            // ----- Cargo & pickup ----------------------------------------
            InfoRow(
              icon: Icons.inventory_2_outlined,
              label: '${trip.crateCount} crates · '
                  '${trip.weightKg.toStringAsFixed(0)} kg',
            ),
            const SizedBox(height: 6),
            InfoRow(
              icon: Icons.location_on_outlined,
              label: 'Pickup: $pickupDisplay',
              onNavigate: () => launchMaps(
                context,
                '${trip.latitude},${trip.longitude}',
              ),
            ),
            const SizedBox(height: 6),
            InfoRow(
              icon: Icons.flag_outlined,
              label: 'Dropoff: ${dropoff.isEmpty ? "—" : dropoff}',
              onNavigate: dropoff.isEmpty
                  ? null
                  : () => launchMaps(context, dropoff),
            ),

            // ----- Farmer Contact Card -----------------------------------
            // Rendered only when the backend has unlocked the farmer's
            // contact info (i.e. a rider has been assigned and the farmer
            // has a phone number on file). Handles the transition case:
            // an ACCEPTED trip from an older session may not carry the
            // new fields, in which case `hasFarmerContact` is false and
            // the card is silently skipped.
            if (trip.hasFarmerContact) ...[
              const SizedBox(height: 14),
              _FarmerContactCard(trip: trip),
            ],

            const SizedBox(height: 16),
            _buildActionButton(),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButton() {
    if (trip.status == 'ACCEPTED') {
      // Primary action: verify the 4-digit OTP the farmer reads out.
      return SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: isUpdating ? null : onEnterOtp,
          icon: isUpdating
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.pin),
          label: const Text('Enter Pickup OTP'),
          style: FilledButton.styleFrom(
            backgroundColor: kRiderGreen,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
      );
    }

    if (_kCompletableTripStatuses.contains(trip.status)) {
      // Deliver requires proof of delivery.
      return SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: isUpdating ? null : onMarkDelivered,
          icon: isUpdating
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.camera_alt_outlined),
          label: Text(isUpdating ? 'Updating…' : 'Mark Delivered'),
          style: FilledButton.styleFrom(
            backgroundColor: kRiderGreen,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
      );
    }

    // Terminal state (shouldn't normally appear here — the endpoint filters
    // to ACCEPTED/PICKED_UP — but render something sane if it does).
    return const SizedBox.shrink();
  }
}

// ---------------------------------------------------------------------------
// Farmer contact card
// ---------------------------------------------------------------------------

/// Small green-tinted card with the farmer's name, pickup address, and a
/// prominent CALL FARMER button.
///
/// ## Why this is separate from the trip card
///
/// Contact info is a distinct concern from trip logistics — the trip card
/// renders cargo, addresses, and status; this card renders "who to call and
/// where to meet them". Separating them makes it easy to move the contact
/// card to a different position (e.g. above the action button vs below),
/// and makes it obvious where the privacy gating lives: if `hasFarmerContact`
/// is false, nothing here renders at all.
class _FarmerContactCard extends StatelessWidget {
  const _FarmerContactCard({required this.trip});

  final ActiveTrip trip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Fall back to a generic label if the backend didn't send a name.
    final name = (trip.farmerFullName != null &&
            trip.farmerFullName!.trim().isNotEmpty)
        ? trip.farmerFullName!.trim()
        : 'Farmer';

    // Pickup display mirrors the trip card's fallback logic.
    final pickup = (trip.pickupAddress != null &&
            trip.pickupAddress!.trim().isNotEmpty)
        ? trip.pickupAddress!.trim()
        : null;

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
          // ----- Header ------------------------------------------------
          Row(
            children: [
              const Icon(Icons.agriculture_outlined,
                  color: kRiderGreen, size: 18),
              const SizedBox(width: 8),
              Text(
                'Farmer Contact',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: kRiderGreen,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // ----- Name + phone ------------------------------------------
          Row(
            children: [
              const Icon(Icons.person_outline,
                  size: 18, color: Colors.black54),
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
          const SizedBox(height: 6),
          Row(
            children: [
              const Icon(Icons.phone_outlined,
                  size: 18, color: Colors.black54),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '+91 ${trip.farmerPhoneNumber}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
            ],
          ),

          // ----- Pickup address (only if available) --------------------
          if (pickup != null) ...[
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Icon(Icons.location_on_outlined,
                      size: 18, color: Colors.black54),
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

          const SizedBox(height: 12),

          // ----- CALL FARMER button ------------------------------------
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () =>
                  launchPhoneCall(context, trip.farmerPhoneNumber!),
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
              label: const Text('CALL FARMER'),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Delivery proof-of-photo dialog
// ---------------------------------------------------------------------------

class _DeliveryProofDialog extends StatefulWidget {
  const _DeliveryProofDialog({required this.onSubmit});

  final Future<DeliveryResult> Function(
    Uint8List photoBytes,
    String sourceFilename,
  ) onSubmit;

  @override
  State<_DeliveryProofDialog> createState() => _DeliveryProofDialogState();
}

class _DeliveryProofDialogState extends State<_DeliveryProofDialog> {
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
      // ignore: avoid_print
      print('Dialog submit error: $e');
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
              const Text(
                'Take a photo of the delivered crates at the mandi. '
                'This is required before the trip can be completed.',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 16),

              if (_imageBytes == null)
                Container(
                  height: 180,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest
                        .withOpacity(0.4),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: const Center(
                    child: Icon(Icons.image_outlined,
                        size: 48, color: Colors.black26),
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
                    errorBuilder: (_, __, ___) => Container(
                      height: 200,
                      width: 320,
                      color: Colors.grey.shade200,
                      alignment: Alignment.center,
                      child: const Icon(Icons.broken_image_outlined,
                          size: 48, color: Colors.black26),
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
                      icon: const Icon(Icons.camera_alt_outlined, size: 18),
                      label: const Text('Camera'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _isUploading
                          ? null
                          : () => _pick(ImageSource.gallery),
                      icon: const Icon(Icons.photo_library_outlined, size: 18),
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
                    color: theme.colorScheme.errorContainer.withOpacity(0.4),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.error_outline,
                          size: 16, color: theme.colorScheme.error),
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
          onPressed: _isUploading ? null : () => Navigator.of(context).pop(),
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

// ---------------------------------------------------------------------------
// OTP verification dialog
// ---------------------------------------------------------------------------

class _OtpDialog extends StatefulWidget {
  const _OtpDialog({
    required this.cropName,
    required this.onSubmit,
  });

  final String cropName;
  final Future<OtpSubmitResult> Function(String otp) onSubmit;

  @override
  State<_OtpDialog> createState() => _OtpDialogState();
}

class _OtpDialogState extends State<_OtpDialog> {
  final _formKey = GlobalKey<FormState>();
  final _controller = TextEditingController();
  bool _isSubmitting = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isSubmitting = true;
      _error = null;
    });

    try {
      final result = await widget.onSubmit(_controller.text.trim());
      if (!mounted) return;

      if (result == OtpSubmitResult.success) {
        Navigator.of(context).pop(true);
        return;
      }

      setState(() {
        _error = result == OtpSubmitResult.invalidOtp
            ? 'Invalid OTP. Please check with the farmer.'
            : 'Could not verify OTP. Please try again.';
      });
    } catch (e) {
      debugPrint('OTP dialog submit error: $e');
      // ignore: avoid_print
      print('OTP dialog submit error: $e');
      if (!mounted) return;
      setState(() => _error = 'Error: $e');
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Enter Pickup OTP'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Ask the farmer for the 4-digit code shown on their screen.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _controller,
              enabled: !_isSubmitting,
              autofocus: true,
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
              ),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                counterText: '',
                hintText: '••••',
              ),
              validator: (v) {
                final value = (v ?? '').trim();
                if (value.isEmpty) return 'Enter the OTP';
                if (value.length != 4) return 'OTP must be 4 digits';
                return null;
              },
              onFieldSubmitted: (_) {
                if (!_isSubmitting) _submit();
              },
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      actions: [
        TextButton(
          onPressed: _isSubmitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _isSubmitting ? null : _submit,
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
          label: Text(_isSubmitting ? 'Verifying…' : 'Verify & Pick Up'),
          style: FilledButton.styleFrom(
            backgroundColor: kRiderGreen,
          ),
        ),
      ],
    );
  }
}