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
/// PICKED_UP), with status-transition actions, the pickup OTP dialog, and the
/// proof-of-delivery photo upload flow.
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

        // Defensive: the endpoint currently returns a single object. When it
        // is upgraded to return a list, this branch keeps working without a
        // client change.
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
            content: Text('${trip.produceRequest.cropType} → $newStatus'),
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
  /// The verify endpoint targets the ProduceRequest id (not the Trip id) —
  /// `trip.produceRequest.id`. On a successful verify, the ProduceRequest's
  /// status flips to PICKED_UP on the server, but the Trip status stays
  /// ACCEPTED (they're independent state machines). Since the rider's card
  /// reads the Trip status, we follow up with a PATCH to sync the two —
  /// otherwise the card would still say "ACCEPTED" and the OTP button would
  /// keep appearing.
  ///
  /// If the PATCH fails, we still return success — the OTP was verified,
  /// which is the essential operation. The user sees the green SnackBar and
  /// the list refreshes; the card may still show ACCEPTED until the next
  /// successful status PATCH. Backend-side, folding the trip transition
  /// into the verify endpoint would remove this two-call dance entirely.
  Future<OtpSubmitResult> _submitOtp(ActiveTrip trip, String otp) async {
    final auth = context.read<AuthProvider>();
    if (auth.token == null) return OtpSubmitResult.otherError;

    try {
      final verifyResp = await http.post(
        Uri.parse(
          '$kApiBaseUrl/produce-requests/${trip.produceRequest.id}/verify-otp',
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
        cropName: trip.produceRequest.cropType,
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
  ///      {image_url}. We don't currently persist the URL against the Trip
  ///      (no column for it), so it's simply uploaded for audit trail.
  ///   2. PATCH /trips/{id}/status with {"status": "DELIVERED"}.
  ///
  /// Takes `Uint8List` plus the source filename (not a `File`) so the same
  /// code path works on Flutter Web, Android, and iOS — `File` isn't
  /// available on Web, and reading the picked image into memory once here
  /// avoids platform-specific branching.
  ///
  /// The multipart body is built with `MultipartFile.fromBytes` and an
  /// explicit `contentType`, because `fromBytes` defaults to
  /// `application/octet-stream` and the backend's content-type allowlist
  /// (`image/jpeg`, `image/png`, `image/webp`) will reject that outright.
  /// The MIME type is derived from the source filename's extension.
  ///
  /// Every network call is bounded by [_kUploadTimeout]; on expiry, the
  /// returned [DeliveryResult.failure] carries a specific "Connection timed
  /// out" message the dialog surfaces verbatim. Combined with the dialog's
  /// own try-catch-finally, this guarantees the spinner never sticks.
  ///
  /// On any failure returns a [DeliveryResult.failure] whose `errorMessage`
  /// is the backend's exact `detail` string when one is present — the dialog
  /// surfaces it verbatim so the rider knows *why* the request was rejected
  /// (e.g. "Unsupported file type: application/octet-stream.") rather than
  /// seeing a generic "try again".
  Future<DeliveryResult> _uploadProofAndDeliver(
    ActiveTrip trip,
    Uint8List imageBytes,
    String sourceFilename,
  ) async {
    // ----- Pre-condition: trip must be in a completable state -----------
    // Mirrors the backend's own guard. Checking here too means the rider
    // gets an instant, clear rejection instead of a wasted network round
    // trip and a parsed 400.
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

      // Derive the MIME subtype from the picked file's extension. The
      // image_picker package returns whatever the platform gave it — on
      // Android that's often a cache path ending in `.jpg`, on Web it's
      // the original upload's name. We lowercase and normalize `.jpeg` /
      // `.jpg` to the same value since both are `image/jpeg` on the wire.
      final extension = _mimeSubtypeFromFilename(sourceFilename);

      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          imageBytes,
          filename: 'proof.$extension',
          contentType: MediaType('image', extension),
        ),
      );

      // `.timeout` guards against a socket that accepts the connection but
      // never responds — without it, `await` would hang indefinitely and
      // the dialog's spinner would never clear. Throws TimeoutException on
      // expiry, caught below with a specific message.
      final streamed = await request
          .send()
          .timeout(_kUploadTimeout);

      final uploadResp = await http.Response.fromStream(streamed)
          .timeout(_kUploadTimeout);

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
      // Specific message so the rider knows it's a network problem, not
      // something wrong with their photo or the trip state.
      debugPrint('Upload Error (timeout): $e');
      // ignore: avoid_print
      print('Upload Error (timeout): $e');
      return const DeliveryResult.failure(
        'Connection timed out. Please check backend server.',
      );
    } catch (e) {
      // Log to the browser console (F12) / device log for debugging.
      debugPrint('Upload Error: $e');
      // ignore: avoid_print
      print('Upload Error: $e');
      return DeliveryResult.failure('Error: $e');
    }
  }

  /// Maps a source filename to the MIME subtype the backend expects.
  ///
  /// `image/jpeg` is the canonical MIME for both `.jpg` and `.jpeg` — the
  /// backend's allowlist only knows `image/jpeg`, so we normalize `.jpg` to
  /// `jpeg` here rather than sending `image/jpg` (which is not a real MIME
  /// type and would be rejected). Unknown extensions default to `jpeg`
  /// because image_picker's own output on every platform we target is
  /// either JPEG or, occasionally, PNG — and a JPEG-typed payload of PNG
  /// bytes is still accepted by PIL/Flask on the server side for reading
  /// dimensions, even if it's technically a mismatch.
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
        // Fall back to the safest option — see doc comment.
        return 'jpeg';
    }
  }

  /// Pulls the human-readable reason out of a FastAPI error response.
  ///
  /// FastAPI puts the actual explanation in `{"detail": "..."}`, so we look
  /// for that field first. If the body isn't JSON or has no detail, we fall
  /// back to the caller-supplied message (which usually embeds the HTTP
  /// status code). Truncates very long bodies so a stack trace doesn't
  /// overflow the dialog.
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
    // Guard at the entry point too — if the trip moved out of PICKED_UP
    // between render and tap (e.g. another device cancelled it), we don't
    // want to open the dialog at all.
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

  /// Called from the PICKED_UP branch. Opens the proof-of-delivery dialog,
  /// which internally uploads the photo and PATCHes the status — so this
  /// callback replaces the old direct `onUpdateStatus('DELIVERED')` call.
  final VoidCallback onMarkDelivered;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pr = trip.produceRequest;
    final dropoff = pr.dropoffLocation ?? '';

    return Card(
      elevation: 1,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    pr.cropType,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                StatusBadge(status: trip.status),
              ],
            ),
            const SizedBox(height: 12),
            InfoRow(
              icon: Icons.inventory_2_outlined,
              label: '${pr.crateCount} crates · '
                  '${pr.weightKg.toStringAsFixed(0)} kg',
            ),
            const SizedBox(height: 6),
            InfoRow(
              icon: Icons.location_on_outlined,
              label: 'Pickup: '
                  '${pr.latitude.toStringAsFixed(4)}, '
                  '${pr.longitude.toStringAsFixed(4)}',
              onNavigate: () => launchMaps(
                context,
                '${pr.latitude},${pr.longitude}',
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
            const SizedBox(height: 16),
            _buildActionButton(),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButton() {
    if (trip.status == 'ACCEPTED') {
      // Primary action: verify the 4-digit OTP the farmer reads out. This
      // is what actually confirms the handoff on the backend.
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
      // Deliver requires proof of delivery — the dialog handles the photo
      // upload and the status PATCH, then pops with success.
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
// Delivery proof-of-photo dialog
// ---------------------------------------------------------------------------

class _DeliveryProofDialog extends StatefulWidget {
  const _DeliveryProofDialog({required this.onSubmit});

  /// Uploads the photo and transitions the trip. Returns a [DeliveryResult]
  /// the dialog uses to decide whether to close (success) or keep itself
  /// open and show the backend's exact rejection reason.
  ///
  /// Takes raw bytes and the source filename (not a File) so the same
  /// widget compiles and works identically on Flutter Web, Android, and iOS.
  /// The filename is what the parent uses to derive the multipart
  /// Content-Type — see `_mimeSubtypeFromFilename` in the parent state.
  final Future<DeliveryResult> Function(
    Uint8List photoBytes,
    String sourceFilename,
  ) onSubmit;

  @override
  State<_DeliveryProofDialog> createState() => _DeliveryProofDialogState();
}

class _DeliveryProofDialogState extends State<_DeliveryProofDialog> {
  final ImagePicker _picker = ImagePicker();

  /// The picked XFile. Kept alongside the bytes so we have the filename and
  /// MIME metadata available when building the multipart request — the
  /// parent uses its `.name` to decide the Content-Type it sends.
  XFile? _pickedFile;

  /// Picked image bytes. `Uint8List` (not `dart:io File`) so `Image.memory`
  /// renders it on every platform — Web has no filesystem paths, and
  /// `Image.file` asserts `!kIsWeb`.
  Uint8List? _imageBytes;

  bool _isUploading = false;
  String? _error;

  Future<void> _pick(ImageSource source) async {
    try {
      final picked = await _picker.pickImage(
        source: source,
        // Downscale before upload — a 12MP photo is 4–8MB and the backend
        // caps at 10MB; 1600px at 85% quality is plenty for a proof shot
        // and uploads in well under a second on 4G. On Web these options
        // are applied via canvas during the picker round-trip.
        maxWidth: 1600,
        imageQuality: 85,
      );
      if (picked == null) return;

      // Read bytes immediately while the platform file handle is still
      // valid. On Web there's no path to reopen, so this is the only
      // moment the bytes are guaranteed available.
      final bytes = await picked.readAsBytes();
      if (!mounted) return;

      setState(() {
        _pickedFile = picked;
        _imageBytes = bytes;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      // On Web, the most common failure is the browser blocking camera
      // access (permissions, no webcam on desktop, or an insecure origin).
      // Surface a hint rather than the raw exception so the rider knows
      // what to try next.
      final hint = kIsWeb
          ? ' (if using Camera, try Gallery instead — browsers often block '
              'camera access on non-HTTPS origins or desktops without a webcam)'
          : '';
      setState(() => _error = 'Could not pick image: $e$hint');
    }
  }

  /// Runs the upload and always clears [_isUploading] on the way out.
  ///
  /// The try-catch-finally structure is load-bearing: without it, an
  /// exception thrown by `widget.onSubmit` (which shouldn't happen — the
  /// parent catches everything — but defensive coding wins) would propagate
  /// out and leave the spinner stuck. With `finally` guaranteeing the
  /// `setState`, the loading UI clears no matter how the future resolves:
  /// success, caught failure, or uncaught exception.
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

    // Pass the original filename along so the parent can derive a proper
    // Content-Type. If the picker somehow gave us no name (shouldn't happen
    // in practice), fall back to a `.jpg` default — the parent's MIME helper
    // normalizes to `image/jpeg` from there.
    final filename = _pickedFile?.name ?? 'proof.jpg';

    try {
      final result = await widget.onSubmit(bytes, filename);

      if (!mounted) return;

      if (result.success) {
        Navigator.of(context).pop(true);
        return;
      }

      // Surface the backend's actual reason verbatim. Falls back to a
      // generic message only if the server gave us nothing parseable.
      setState(() {
        _error = result.errorMessage ??
            'Could not complete delivery. Please try again.';
      });
    } catch (e) {
      // Should never fire — the parent catches everything — but if it
      // does, the finally block below still resets the spinner, and the
      // error is shown inline so the rider isn't left staring at a
      // disabled button.
      debugPrint('Dialog submit error: $e');
      // ignore: avoid_print
      print('Dialog submit error: $e');
      if (!mounted) return;
      setState(() => _error = 'Error: $e');
    } finally {
      // Guarantee: if the dialog is still on screen, the loading state is
      // cleared. If it's already been popped (success path), `mounted` is
      // false and we skip the setState — harmless either way.
      if (mounted) {
        setState(() => _isUploading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Explicit width on the content is load-bearing on Flutter Web: an
    // AlertDialog's intrinsic sizing can collapse to zero when its child
    // mixes CrossAxisAlignment.stretch with an Image whose width is
    // `double.infinity`, producing a "blank modal". Pinning a width here
    // removes the ambiguity.
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

              // ----- Preview ----------------------------------------------
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
                    // Web rendering sometimes flickers when the widget
                    // rebuilds mid-decode; gaplessPlayback keeps the
                    // previous frame visible instead of a flash of blank.
                    gaplessPlayback: true,
                    // If the bytes aren't a decodable image for any reason,
                    // show a placeholder instead of the red Flutter error box.
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

              // ----- Pick buttons -----------------------------------------
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

              // ----- Upload progress --------------------------------------
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

  /// Performs the actual network calls. Returns a result the dialog uses
  /// to decide whether to close (success) or show an inline error and let
  /// the rider retry without losing the dialog.
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
      // Same defensive guarantee as the delivery dialog — if the parent
      // ever throws, the spinner still clears.
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