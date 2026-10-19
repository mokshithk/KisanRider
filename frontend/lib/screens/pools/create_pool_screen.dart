import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';

String get _kApiBaseUrl {
  if (kIsWeb) return 'http://localhost:8000';
  return 'http://10.28.1.142:8000';
}

const Color _kFarmerGreen = Color(0xFF2E7D32);

class CreatePoolScreen extends StatefulWidget {
  const CreatePoolScreen({super.key});

  @override
  State<CreatePoolScreen> createState() => _CreatePoolScreenState();
}

class _CreatePoolScreenState extends State<CreatePoolScreen> {
  final _formKey = GlobalKey<FormState>();

  List<Map<String, dynamic>> _pendingRequests = [];
  Map<String, dynamic>? _selectedRequest;

  final _maxQtyController = TextEditingController();
  final _weightController = TextEditingController();

  DateTime? _windowStart;
  DateTime? _windowEnd;

  bool _isLoadingRequests = true;
  bool _isSubmitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _fetchRequests());
  }

  @override
  void dispose() {
    _maxQtyController.dispose();
    _weightController.dispose();
    super.dispose();
  }

  Future<void> _fetchRequests() async {
    final auth = context.read<AuthProvider>();
    try {
      final resp = await http.get(
        Uri.parse('$_kApiBaseUrl/produce-requests/farmer/me'),
        headers: {
          'Authorization': 'Bearer ${auth.token}',
          'Accept': 'application/json',
        },
      );
      if (!mounted) return;

      if (resp.statusCode == 200) {
        final list = (jsonDecode(resp.body) as List<dynamic>)
            .whereType<Map<String, dynamic>>()
            .where((r) => r['status'] == 'PENDING')
            .toList();

        setState(() {
          _pendingRequests = list;
          _isLoadingRequests = false;
        });
      } else {
        setState(() {
          _error = 'Failed to load pending requests.';
          _isLoadingRequests = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Network error: $e';
        _isLoadingRequests = false;
      });
    }
  }

  void _onRequestSelected(String? id) {
    if (id == null) return;
    final req = _pendingRequests.firstWhere((r) => r['id'].toString() == id);
    setState(() {
      _selectedRequest = req;
      _weightController.text = (req['weight_kg'] as num?)?.toStringAsFixed(0) ?? '';
    });
  }

  Future<void> _pickDateTime({required bool isStart}) async {
    final initialDate = DateTime.now().add(const Duration(days: 1));
    final date = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 30)),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(primary: _kFarmerGreen),
          ),
          child: child!,
        );
      },
    );
    if (date == null) return;

    if (!mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(primary: _kFarmerGreen),
          ),
          child: child!,
        );
      },
    );
    if (time == null) return;

    final dt = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    setState(() {
      if (isStart) {
        _windowStart = dt;
        if (_windowEnd != null && _windowEnd!.isBefore(dt)) {
          _windowEnd = null;
        }
      } else {
        _windowEnd = dt;
      }
    });
  }

  String _formatDateTime(DateTime? dt) {
    if (dt == null) return 'Select Date & Time';
    return '${dt.day}/${dt.month}/${dt.year} at ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedRequest == null) {
      _showError('Please select a produce request.');
      return;
    }
    if (_windowStart == null || _windowEnd == null) {
      _showError('Please select the pickup window.');
      return;
    }

    setState(() {
      _isSubmitting = true;
      _error = null;
    });

    final auth = context.read<AuthProvider>();
    final pr = _selectedRequest!;

    final payload = {
      'produce_request_id': pr['id'],
      'weight_kg': double.parse(_weightController.text),
      'crop_type': pr['crop_type'] ?? 'Unknown',
      'pickup_window_start': _windowStart!.toUtc().toIso8601String(),
      'pickup_window_end': _windowEnd!.toUtc().toIso8601String(),
      'min_qty': 50.0, // Defaulting min to 50kg for simplicity
      'max_qty': double.parse(_maxQtyController.text),
      'dropoff_district': pr['dropoff_district'],
      'dropoff_mandi_name': pr['dropoff_mandi_name'],
      'auto_approve': true,
    };

    try {
      final resp = await http.post(
        Uri.parse('$_kApiBaseUrl/pools/'),
        headers: {
          'Authorization': 'Bearer ${auth.token}',
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode(payload),
      );

      if (!mounted) return;

      if (resp.statusCode == 201) {
        Navigator.of(context).pop(true);
      } else {
        final body = jsonDecode(resp.body);
        setState(() {
          _isSubmitting = false;
          _error = body['detail']?.toString() ?? 'Failed to create pool.';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _error = 'Network error: $e';
      });
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red.shade700),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Create a Pool'),
        backgroundColor: _kFarmerGreen,
        foregroundColor: Colors.white,
      ),
      body: _isLoadingRequests
          ? const Center(child: CircularProgressIndicator())
          : _pendingRequests.isEmpty
              ? _buildEmptyState(theme)
              : _buildForm(theme),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inbox_outlined, size: 64, color: Colors.grey.shade400),
            const SizedBox(height: 16),
            Text(
              'No pending requests found.',
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              'You need an active produce request to create a pool. Book transport first.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildForm(ThemeData theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Pool Details',
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              'Combine your harvest with nearby farmers to share transport costs.',
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey.shade600),
            ),
            const SizedBox(height: 24),

            DropdownButtonFormField<String>(
              value: _selectedRequest?['id'],
              decoration: const InputDecoration(
                labelText: 'Select Produce to Pool',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.eco_outlined),
              ),
              items: _pendingRequests.map((r) {
                final crop = r['crop_type'] ?? 'Crop';
                final wt = (r['weight_kg'] as num?)?.toStringAsFixed(0) ?? '0';
                return DropdownMenuItem<String>(
                  value: r['id'].toString(),
                  child: Text('$crop ($wt kg)'),
                );
              }).toList(),
              onChanged: _onRequestSelected,
              validator: (v) => v == null ? 'Required' : null,
            ),
            const SizedBox(height: 16),

            if (_selectedRequest != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _kFarmerGreen.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _kFarmerGreen.withOpacity(0.2)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.store, size: 16, color: _kFarmerGreen),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Destination: ${_selectedRequest!['dropoff_mandi_name'] ?? 'N/A'}',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],

            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _weightController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Your Weight (kg)',
                      border: OutlineInputBorder(),
                      suffixText: 'kg',
                    ),
                    validator: (v) {
                      if (v == null || v.isEmpty) return 'Required';
                      final d = double.tryParse(v);
                      if (d == null || d <= 0) return 'Invalid';
                      return null;
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _maxQtyController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Max Pool (kg)',
                      border: OutlineInputBorder(),
                      suffixText: 'kg',
                    ),
                    validator: (v) {
                      if (v == null || v.isEmpty) return 'Required';
                      final d = double.tryParse(v);
                      if (d == null || d <= 0) return 'Invalid';
                      return null;
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            Text(
              'Pickup Window',
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            InkWell(
              onTap: () => _pickDateTime(isStart: true),
              child: InputDecorator(
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.calendar_today),
                  labelText: 'Starts',
                ),
                child: Text(_formatDateTime(_windowStart)),
              ),
            ),
            const SizedBox(height: 12),
            InkWell(
              onTap: () => _pickDateTime(isStart: false),
              child: InputDecorator(
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.calendar_today),
                  labelText: 'Ends',
                ),
                child: Text(_formatDateTime(_windowEnd)),
              ),
            ),
            const SizedBox(height: 32),

            if (_error != null) ...[
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              const SizedBox(height: 16),
            ],

            FilledButton(
              onPressed: _isSubmitting ? null : _submit,
              style: FilledButton.styleFrom(
                backgroundColor: _kFarmerGreen,
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: _isSubmitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                    )
                  : const Text('Create Pool'),
            ),
          ],
        ),
      ),
    );
  }
}