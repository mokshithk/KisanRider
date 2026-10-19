import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import 'pool_models.dart';
import 'pools_api.dart';

String get _kApiBaseUrl {
  if (kIsWeb) return 'http://localhost:8000';
  return 'http://10.28.1.142:8000';
}

const Color _kFarmerGreen = Color(0xFF2E7D32);
const Color _kBackground = Color(0xFFF8F9FA);
const Color _kTextPrimary = Color(0xFF1C1B1F);
const Color _kTextSecondary = Color(0xFF6B7280);

class PoolDetailScreen extends StatefulWidget {
  final String poolId;

  const PoolDetailScreen({super.key, required this.poolId});

  @override
  State<PoolDetailScreen> createState() => _PoolDetailScreenState();
}

class _PoolDetailScreenState extends State<PoolDetailScreen> {
  PoolDetail? _pool;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadDetail());
  }

  Future<void> _loadDetail() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    final auth = context.read<AuthProvider>();
    try {
      final detail = await PoolsApi.fetchPoolDetail(
        token: auth.token!,
        poolId: widget.poolId,
      );
      if (!mounted) return;
      setState(() {
        _pool = detail;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceAll('Exception: ', '');
        _isLoading = false;
      });
    }
  }

  Future<void> _showJoinSheet() async {
    final auth = context.read<AuthProvider>();
    List<Map<String, dynamic>> pending = [];

    // Show loading dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final resp = await http.get(
        Uri.parse('$_kApiBaseUrl/produce-requests/farmer/me'),
        headers: {'Authorization': 'Bearer ${auth.token}', 'Accept': 'application/json'},
      );
      if (resp.statusCode == 200) {
        pending = (jsonDecode(resp.body) as List<dynamic>)
            .whereType<Map<String, dynamic>>()
            .where((r) => r['status'] == 'PENDING')
            .toList();
      }
    } catch (_) {}

    if (!mounted) return;
    Navigator.of(context).pop(); // dismiss loading

    if (pending.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No pending requests available to join with.'), backgroundColor: Colors.red),
      );
      return;
    }

    // Show bottom sheet
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => _JoinPoolSheet(
        poolId: widget.poolId,
        pendingRequests: pending,
        authToken: auth.token!,
      ),
    );

    if (result == true) {
      _loadDetail();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBackground,
      appBar: AppBar(
        title: const Text('Pool Details'),
        backgroundColor: _kFarmerGreen,
        foregroundColor: Colors.white,
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(color: _kFarmerGreen));
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: _loadDetail, child: const Text('Retry')),
          ],
        ),
      );
    }
    if (_pool == null) return const SizedBox();

    final pool = _pool!;
    final isCreator = context.read<AuthProvider>().userId == pool.creatorId;
    final isMember = pool.members.any((m) => m.farmerId == context.read<AuthProvider>().userId);
    final canJoin = pool.status == 'OPEN' && !isMember;

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHeaderCard(pool),
                const SizedBox(height: 16),
                _buildInfoCard('Members (${pool.members.length})', [
                  ...pool.members.map((m) => ListTile(
                        leading: const CircleAvatar(
                          backgroundColor: Color(0x1F2E7D32),
                          child: Icon(Icons.person, color: _kFarmerGreen, size: 20),
                        ),
                        title: Text(
                          m.farmerId == pool.creatorId ? 'You (Creator)' : 'Farmer ${m.farmerId.substring(0, 4)}',
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text('${m.weightKg.toStringAsFixed(0)} kg · ${m.status}', style: const TextStyle(fontSize: 12)),
                        dense: true,
                      )),
                ]),
              ],
            ),
          ),
        ),
        if (pool.status == 'OPEN')
          Container(
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(top: BorderSide(color: Colors.black12)),
            ),
            child: SafeArea(
              child: ElevatedButton(
                onPressed: canJoin ? _showJoinSheet : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _kFarmerGreen,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: Text(isCreator ? 'You created this pool' : isMember ? 'You have joined this pool' : 'Join Pool'),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildHeaderCard(PoolDetail pool) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${pool.cropType} Pool',
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: _kTextPrimary),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.green.shade300),
                ),
                child: Text(pool.status, style: TextStyle(color: Colors.green.shade800, fontWeight: FontWeight.bold, fontSize: 11)),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildRow(Icons.storefront, 'Destination', pool.dropoffMandiName ?? 'Unknown'),
          const SizedBox(height: 12),
          _buildRow(Icons.scale, 'Capacity', '${pool.currentQty.toStringAsFixed(0)} / ${pool.maxQty.toStringAsFixed(0)} kg'),
          const SizedBox(height: 12),
          _buildRow(Icons.access_time, 'Window', '${_formatDate(pool.pickupWindowStart)} - ${_formatDate(pool.pickupWindowEnd)}'),
        ],
      ),
    );
  }

  Widget _buildRow(IconData icon, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: _kTextSecondary),
        const SizedBox(width: 8),
        SizedBox(
          width: 80,
          child: Text(label, style: const TextStyle(fontSize: 13, color: _kTextSecondary)),
        ),
        Expanded(
          child: Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _kTextPrimary)),
        ),
      ],
    );
  }

  Widget _buildInfoCard(String title, List<Widget> children) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: _kTextPrimary)),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final local = dt.toLocal();
    return '${local.day}/${local.month} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
}

class _JoinPoolSheet extends StatefulWidget {
  final String poolId;
  final List<Map<String, dynamic>> pendingRequests;
  final String authToken;

  const _JoinPoolSheet({
    required this.poolId,
    required this.pendingRequests,
    required this.authToken,
  });

  @override
  State<_JoinPoolSheet> createState() => _JoinPoolSheetState();
}

class _JoinPoolSheetState extends State<_JoinPoolSheet> {
  Map<String, dynamic>? _selectedReq;
  final _weightController = TextEditingController();
  bool _isLoading = false;

  @override
  void dispose() {
    _weightController.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    if (_selectedReq == null) return;
    final weight = double.tryParse(_weightController.text);
    if (weight == null || weight <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter a valid weight'), backgroundColor: Colors.red));
      return;
    }

    setState(() => _isLoading = true);

    try {
      await PoolsApi.joinPool(
        token: widget.authToken,
        poolId: widget.poolId,
        produceRequestId: _selectedReq!['id'],
        weightKg: weight,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceAll('Exception: ', '')), backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom, left: 20, right: 20, top: 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Join Pool', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            value: _selectedReq?['id'],
            decoration: const InputDecoration(labelText: 'Select Produce to Pool', border: OutlineInputBorder()),
            items: widget.pendingRequests.map((r) {
              final crop = r['crop_type'] ?? 'Crop';
              final wt = (r['weight_kg'] as num?)?.toStringAsFixed(0) ?? '0';
              return DropdownMenuItem<String>(
                value: r['id'].toString(),
                child: Text('$crop ($wt kg)'),
              );
            }).toList(),
            onChanged: (v) {
              if (v == null) return;
              setState(() {
                _selectedReq = widget.pendingRequests.firstWhere((r) => r['id'].toString() == v);
                _weightController.text = (_selectedReq!['weight_kg'] as num?)?.toStringAsFixed(0) ?? '';
              });
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _weightController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Your Contribution (kg)', border: OutlineInputBorder(), suffixText: 'kg'),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _isLoading || _selectedReq == null ? null : _join,
            style: FilledButton.styleFrom(backgroundColor: _kFarmerGreen, padding: const EdgeInsets.symmetric(vertical: 14)),
            child: _isLoading
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                : const Text('Confirm Join'),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}