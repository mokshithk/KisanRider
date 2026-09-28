import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import 'rider_common.dart';

/// Tab 1 of the rider shell: the rider's currently active trips (ACCEPTED or
/// PICKED_UP), with status-transition actions and the pickup OTP dialog.
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
  });

  final ActiveTrip trip;
  final bool isUpdating;
  final void Function(String newStatus) onUpdateStatus;
  final VoidCallback onEnterOtp;

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

    if (trip.status == 'PICKED_UP') {
      return SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: isUpdating ? null : () => onUpdateStatus('DELIVERED'),
          icon: isUpdating
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.check_circle_outline),
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

    final result = await widget.onSubmit(_controller.text.trim());
    if (!mounted) return;

    if (result == OtpSubmitResult.success) {
      Navigator.of(context).pop(true);
      return;
    }

    setState(() {
      _isSubmitting = false;
      _error = result == OtpSubmitResult.invalidOtp
          ? 'Invalid OTP. Please check with the farmer.'
          : 'Could not verify OTP. Please try again.';
    });
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