import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import 'login_screen.dart';
import 'rider_common.dart';

// ============================================================================
// Logout helper (public — reused by the dashboard AppBar icon)
// ============================================================================

/// Shows the "Are you sure you want to log out?" confirmation dialog, then
/// logs out and navigates to [LoginScreen].
///
/// ## Why this navigates manually
///
/// `login_screen.dart` uses `pushAndRemoveUntil(..., (route) => false)` to
/// route to the dashboard after a successful login. That predicate removes
/// **every** route in the Navigator, including the `MaterialApp.home` route
/// that hosted `_AuthGate`. So by the time the user taps Logout, `_AuthGate`
/// is no longer mounted and cannot react to `notifyListeners()`. The only
/// way back to the login screen is to replace the stack explicitly — which
/// is what this function does.
///
/// `navigator` is captured **before** the `await` on purpose: after the
/// await, `context` may be stale if the widget has already been disposed.
/// The captured `NavigatorState` remains valid for the frame.
Future<void> showLogoutConfirmation(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Log out?'),
      content: const Text('Are you sure you want to log out?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: kRiderGreen,
            foregroundColor: Colors.white,
          ),
          child: const Text('Logout'),
        ),
      ],
    ),
  );

  if (confirmed != true || !context.mounted) return;

  final auth = context.read<AuthProvider>();
  final navigator = Navigator.of(context);

  try {
    await auth.logout();
  } catch (_) {
    // Even if secure-storage cleanup threw, still leave the dashboard.
  }

  navigator.pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => const LoginScreen()),
    (Route<dynamic> route) => false,
  );
}

// ============================================================================
// Rider Account Screen
// ============================================================================

/// Body-only widget designed to be embedded as the Account tab of
/// [RiderDashboard]'s [IndexedStack]. The dashboard's own AppBar provides
/// the surrounding chrome.
///
/// On mount, fetches `GET /rider/account` to populate every field. The
/// profile header renders instantly from [AuthProvider] and upgrades to
/// the fetched values once they arrive. The duty-status switch is
/// optimistic: it flips locally the instant the user taps, then PATCHes;
/// on failure it reverts and shows a red SnackBar.
class RiderAccountScreen extends StatefulWidget {
  const RiderAccountScreen({super.key});

  @override
  State<RiderAccountScreen> createState() => _RiderAccountScreenState();
}

class _RiderAccountScreenState extends State<RiderAccountScreen>
    with AutomaticKeepAliveClientMixin {
  Map<String, dynamic>? _account;
  bool _isLoading = true;
  String? _error;

  /// True while a duty-status PATCH is in flight. Disables the switch so
  /// the user can't spam-toggle and cause a lost-update race.
  bool _isTogglingDuty = false;

  /// Local mirror of `preferred_language` so the picker has something to
  /// render immediately. The backend's RiderProfileUpdate doesn't accept
  /// this field yet, so persistence is local-only for now.
  String _preferredLanguage = 'en';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _fetchAccount());
  }

  // -------------------------------------------------------------------------
  // Networking
  // -------------------------------------------------------------------------

  Map<String, String> _headers(AuthProvider auth, {bool json = false}) {
    final h = <String, String>{
      'Authorization': 'Bearer ${auth.token}',
      'Accept': 'application/json',
    };
    if (json) h['Content-Type'] = 'application/json';
    return h;
  }

  Future<void> _fetchAccount() async {
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
        Uri.parse('$kApiBaseUrl/rider/account'),
        headers: _headers(auth),
      );
      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() {
          _account = data;
          _preferredLanguage =
              (data['preferred_language'] ?? 'en').toString();
          _isLoading = false;
        });
      } else {
        setState(() {
          _error = _extractError(response) ??
              'Failed to load account (HTTP ${response.statusCode}).';
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

  /// Optimistic duty-status toggle.
  ///
  /// Flips the switch's rendered value immediately so the UI feels instant,
  /// then PATCHes. If the request fails, the value is reverted and a red
  /// SnackBar explains why — so the switch never lies about the server's
  /// actual state.
  Future<void> _toggleDutyStatus(bool newValue) async {
    if (_isTogglingDuty) return;

    final auth = context.read<AuthProvider>();
    if (auth.token == null) return;

    // Capture the current value so we can revert on failure.
    final previousValue =
        (_account?['is_on_duty'] as bool?) ?? false;

    // Optimistic update.
    setState(() {
      _isTogglingDuty = true;
      _account = {...?_account, 'is_on_duty': newValue};
    });

    try {
      final response = await http.patch(
        Uri.parse('$kApiBaseUrl/rider/duty-status'),
        headers: _headers(auth, json: true),
        body: jsonEncode({'is_on_duty': newValue}),
      );
      if (!mounted) return;

      if (response.statusCode == 200) {
        // Server returns the full updated account — use it as the new
        // source of truth rather than trusting our optimistic guess.
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() {
          _account = data;
          _isTogglingDuty = false;
        });
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                newValue
                    ? 'You are now On-Duty — accepting trips.'
                    : 'You are now Offline — no new trips will appear.',
              ),
              backgroundColor: kRiderGreen,
              duration: const Duration(seconds: 2),
            ),
          );
      } else {
        // Revert on failure.
        setState(() {
          _account = {...?_account, 'is_on_duty': previousValue};
          _isTogglingDuty = false;
        });
        _showRedSnack(
          _extractError(response) ??
              'Could not update duty status (HTTP ${response.statusCode}).',
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _account = {...?_account, 'is_on_duty': previousValue};
        _isTogglingDuty = false;
      });
      _showRedSnack('Network error: $e');
    }
  }

  // -------------------------------------------------------------------------
  // Field accessors — prefer fetched account, fall back to AuthProvider
  // -------------------------------------------------------------------------

  String get _displayName {
    final fromAccount = _account?['full_name']?.toString() ?? '';
    if (fromAccount.isNotEmpty) return fromAccount;
    final fromAuth = context.read<AuthProvider>().fullName ?? '';
    return fromAuth.isEmpty ? 'Rider' : fromAuth;
  }

  String get _displayEmail {
    final fromAccount = _account?['email']?.toString() ?? '';
    if (fromAccount.isNotEmpty) return fromAccount;
    return context.read<AuthProvider>().email ?? '';
  }

  String get _displayDistrict {
    final fromAccount = _account?['district']?.toString() ?? '';
    if (fromAccount.isNotEmpty) return fromAccount;
    return context.read<AuthProvider>().district ?? '';
  }

  String get _displayRole {
    final fromAccount = _account?['role']?.toString() ?? '';
    if (fromAccount.isNotEmpty) return fromAccount;
    return context.read<AuthProvider>().role ?? 'RIDER';
  }

  bool get _isOnDuty => (_account?['is_on_duty'] as bool?) ?? false;

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  void _showRedSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.red.shade700,
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  void _showGreenSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: kRiderGreen,
        ),
      );
  }

  /// Opens a modal sheet that returns `true` if a PUT succeeded, then
  /// refetches and shows a success toast.
  Future<void> _openSheet(Widget sheet) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => sheet,
    );
    if (changed == true && mounted) {
      _showGreenSnack('Saved successfully.');
      await _fetchAccount();
    }
  }

  Future<void> _onLanguageSelected(String code) async {
    // Local-only — see `_preferredLanguage` comment.
    setState(() => _preferredLanguage = code);
    _showGreenSnack(
      code == 'kn' ? 'Language set to ಕನ್ನಡ.' : 'Language set to English.',
    );
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (_isLoading && _account == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null && _account == null) {
      return _ErrorView(message: _error!, onRetry: _fetchAccount);
    }

    return RefreshIndicator(
      onRefresh: _fetchAccount,
      color: kRiderGreen,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ProfileHeaderCard(
              fullName: _displayName,
              email: _displayEmail,
              district: _displayDistrict,
              role: _displayRole,
            ),
            const SizedBox(height: 16),

            // ----- Duty Status toggle -------------------------------------
            _DutyStatusCard(
              isOnDuty: _isOnDuty,
              isToggling: _isTogglingDuty,
              onChanged: _toggleDutyStatus,
            ),

            // ----- Vehicle & Driver Details -------------------------------
            _SectionHeader(title: 'VEHICLE & DRIVER DETAILS'),
            _SettingsCard(
              children: [
                _SettingsTile(
                  icon: Icons.directions_car_outlined,
                  title: 'Vehicle & License Info',
                  subtitle: 'License, model, plate number, payload',
                  onTap: () => _openSheet(
                    _VehicleDetailsSheet(account: _account),
                  ),
                ),
              ],
            ),

            // ----- Service Area & Routes ----------------------------------
            _SectionHeader(title: 'SERVICE AREA & ROUTES'),
            _SettingsCard(
              children: [
                _SettingsTile(
                  icon: Icons.alt_route_outlined,
                  title: 'Operating Districts & Routes',
                  subtitle: 'Where you want to haul',
                  onTap: () => _openSheet(
                    _RoutesSheet(account: _account),
                  ),
                ),
              ],
            ),

            // ----- Payouts & Banking --------------------------------------
            _SectionHeader(title: 'PAYOUTS & BANKING'),
            _SettingsCard(
              children: [
                _SettingsTile(
                  icon: Icons.account_balance_outlined,
                  title: 'Bank Account & UPI Details',
                  subtitle: 'Where trip earnings are settled',
                  onTap: () => _openSheet(
                    _PayoutDetailsSheet(account: _account),
                  ),
                ),
              ],
            ),

            // ----- Preferences & Security ---------------------------------
            _SectionHeader(title: 'PREFERENCES & SECURITY'),
            _SettingsCard(
              children: [
                _SettingsTile(
                  icon: Icons.language_outlined,
                  title: 'App Language',
                  trailingText: 'English / ಕನ್ನಡ',
                  onTap: () => showModalBottomSheet<void>(
                    context: context,
                    backgroundColor: Colors.transparent,
                    builder: (_) => _LanguagePickerSheet(
                      current: _preferredLanguage,
                      onSelected: _onLanguageSelected,
                    ),
                  ),
                ),
                const Divider(height: 1, indent: 56),
                _SettingsTile(
                  icon: Icons.lock_outline,
                  title: 'Change Password',
                  subtitle: 'Verify with an OTP sent to your email',
                  onTap: () => _openSheet(
                    _ChangePasswordSheet(email: _displayEmail),
                  ),
                ),
              ],
            ),

            // ----- Support & Legal ----------------------------------------
            _SectionHeader(title: 'SUPPORT & LEGAL'),
            _SettingsCard(
              children: [
                _SettingsTile(
                  icon: Icons.headset_mic_outlined,
                  title: 'Rider Helpline & Support',
                  onTap: () => _showInfoDialog(
                    context,
                    title: 'Rider Helpline',
                    body: 'Need help on the road?\n\n'
                        'Rider Helpline: +91 1800 000 111\n'
                        'Email: riders@kisanrider.app\n'
                        'Hours: Mon–Sat, 9 AM to 9 PM IST\n\n'
                        'For safety emergencies, dial 112 directly.\n\n'
                        'Common questions:\n'
                        '• How is my payout calculated? — Tap a completed '
                        'trip under Earnings.\n'
                        '• What if the farmer\'s OTP does not work? — Ask '
                        'them to open My Orders and read the 4-digit code.\n'
                        '• Trip cancelled mid-route? — Contact the helpline '
                        'immediately with the trip ID.',
                  ),
                ),
                const Divider(height: 1, indent: 56),
                _SettingsTile(
                  icon: Icons.gavel_outlined,
                  title: 'Terms & Transport Rules',
                  onTap: () => _showInfoDialog(
                    context,
                    title: 'Transport Rules & Terms',
                    body: 'Guidelines for safe freight hauling on '
                        'KisanRider:\n\n'
                        '1. Verify the pickup OTP before loading any '
                        'crates. Never load without it.\n'
                        '2. Photograph the loaded crates and the delivered '
                        'consignment as proof.\n'
                        '3. Payload limits: do not exceed your vehicle\'s '
                        'declared capacity.\n'
                        '4. Crate handling: stack no more than three high, '
                        'and keep produce out of direct sun.\n'
                        '5. Report accidents or spills within 15 minutes.\n'
                        '6. Earnings settle within 24 hours of a '
                        'successful delivery.\n\n'
                        'By continuing to accept trips you agree to these '
                        'rules and to KisanRider\'s privacy practices.',
                  ),
                ),
              ],
            ),

            const SizedBox(height: 32),

            // ----- Logout --------------------------------------------------
            FilledButton.icon(
              onPressed: () => showLogoutConfirmation(context),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.red.shade600,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                textStyle: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
              icon: const Icon(Icons.exit_to_app_rounded),
              label: const Text('LOG OUT'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showInfoDialog(
    BuildContext context, {
    required String title,
    required String body,
  }) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(body)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            style: TextButton.styleFrom(foregroundColor: kRiderGreen),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// Profile header card
// ============================================================================

class _ProfileHeaderCard extends StatelessWidget {
  const _ProfileHeaderCard({
    required this.fullName,
    required this.email,
    required this.district,
    required this.role,
  });

  final String fullName;
  final String email;
  final String district;
  final String role;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            kRiderGreen.withOpacity(0.12),
            kRiderGreen.withOpacity(0.03),
          ],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: kRiderGreen.withOpacity(0.25)),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: kRiderGreen.withOpacity(0.15),
              shape: BoxShape.circle,
              border: Border.all(
                color: kRiderGreen.withOpacity(0.5),
                width: 2,
              ),
            ),
            child: const Icon(
              Icons.delivery_dining,
              size: 48,
              color: kRiderGreen,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            fullName,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            email.isEmpty ? '—' : email,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              _PillChip(
                icon: Icons.location_on_outlined,
                label: district.isEmpty
                    ? 'Base District: Karnataka'
                    : 'Base District: $district',
                foreground: Colors.grey.shade800,
                background: Colors.white,
                border: Colors.grey.shade300,
              ),
              _PillChip(
                icon: Icons.verified_user_outlined,
                label: 'Role: $role',
                foreground: kRiderGreen,
                background: kRiderGreen.withOpacity(0.15),
                border: kRiderGreen.withOpacity(0.5),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PillChip extends StatelessWidget {
  const _PillChip({
    required this.icon,
    required this.label,
    required this.foreground,
    required this.background,
    required this.border,
  });

  final IconData icon;
  final String label;
  final Color foreground;
  final Color background;
  final Color border;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: foreground),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: foreground,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// Duty status card
// ============================================================================

class _DutyStatusCard extends StatelessWidget {
  const _DutyStatusCard({
    required this.isOnDuty,
    required this.isToggling,
    required this.onChanged,
  });

  final bool isOnDuty;
  final bool isToggling;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Green when online, muted grey when offline — the color itself is a
    // secondary signal so a rider who's glancing at the screen sees the
    // state without reading the label.
    final accent = isOnDuty ? kRiderGreen : Colors.grey.shade600;
    final bgColor = isOnDuty
        ? kRiderGreen.withOpacity(0.10)
        : Colors.grey.shade100;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isOnDuty
              ? kRiderGreen.withOpacity(0.4)
              : Colors.grey.shade300,
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: accent.withOpacity(0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(
              isOnDuty
                  ? Icons.brightness_high_outlined
                  : Icons.brightness_low_outlined,
              color: accent,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'On-Duty Status',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  isOnDuty ? 'Available for Trips' : 'Offline',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          Switch.adaptive(
            value: isOnDuty,
            onChanged: isToggling ? null : onChanged,
            activeColor: kRiderGreen,
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// Section header + settings tile primitives
// ============================================================================

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 24, 4, 10),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: Color(0xFF6B7280),
          letterSpacing: 1.3,
        ),
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Column(children: children),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailingText,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final String? trailingText;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: Icon(icon, color: kRiderGreen),
      title: Text(
        title,
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5),
      ),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (trailingText != null)
            Text(
              trailingText!,
              style: TextStyle(
                fontSize: 13,
                color: Colors.grey.shade700,
                fontWeight: FontWeight.w500,
              ),
            ),
          const SizedBox(width: 4),
          const Icon(Icons.chevron_right, color: Colors.grey),
        ],
      ),
    );
  }
}

// ============================================================================
// Sheet scaffolding
// ============================================================================

class _SheetScaffold extends StatelessWidget {
  const _SheetScaffold({
    required this.title,
    required this.child,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final Widget child;

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
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
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
                Text(
                  title,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: kRiderGreen,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    subtitle!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                child,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SheetSubmitButton extends StatelessWidget {
  const _SheetSubmitButton({
    required this.label,
    required this.isSubmitting,
    required this.onPressed,
  });

  final String label;
  final bool isSubmitting;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: isSubmitting ? null : onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: kRiderGreen,
        padding: const EdgeInsets.symmetric(vertical: 16),
        textStyle: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
        ),
      ),
      child: isSubmitting
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : Text(label),
    );
  }
}

// ============================================================================
// PUT helper — every modal hits a different endpoint with the same shape
// ============================================================================

Future<Map<String, dynamic>?> _putRiderField({
  required BuildContext context,
  required String path,
  required Map<String, dynamic> body,
}) async {
  final auth = context.read<AuthProvider>();
  if (auth.token == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Not signed in.'),
        backgroundColor: Colors.red.shade700,
      ),
    );
    return null;
  }

  try {
    final response = await http.put(
      Uri.parse('$kApiBaseUrl$path'),
      headers: {
        'Authorization': 'Bearer ${auth.token}',
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(body),
    );

    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }

    String message = 'Save failed (HTTP ${response.statusCode}).';
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['detail'] != null) {
        message = decoded['detail'].toString();
      }
    } catch (_) {}
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: Colors.red.shade700,
            behavior: SnackBarBehavior.floating,
          ),
        );
    }
    return null;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('Network error: $e'),
            backgroundColor: Colors.red.shade700,
            behavior: SnackBarBehavior.floating,
          ),
        );
    }
    return null;
  }
}

// ============================================================================
// Sheet 1 — Vehicle & License Info
// ============================================================================

class _VehicleDetailsSheet extends StatefulWidget {
  const _VehicleDetailsSheet({required this.account});

  final Map<String, dynamic>? account;

  @override
  State<_VehicleDetailsSheet> createState() => _VehicleDetailsSheetState();
}

class _VehicleDetailsSheetState extends State<_VehicleDetailsSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _license;
  late final TextEditingController _vehicleType;
  late final TextEditingController _vehicleNumber;
  late final TextEditingController _payload;

  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    final a = widget.account ?? const {};
    _license =
        TextEditingController(text: (a['license_number'] ?? '').toString());
    _vehicleType =
        TextEditingController(text: (a['vehicle_type'] ?? '').toString());
    _vehicleNumber =
        TextEditingController(text: (a['vehicle_number'] ?? '').toString());
    final p = a['payload_capacity_kg'];
    _payload = TextEditingController(
      text: p == null ? '' : p.toString(),
    );
  }

  @override
  void dispose() {
    _license.dispose();
    _vehicleType.dispose();
    _vehicleNumber.dispose();
    _payload.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSubmitting = true);

    final payloadText = _payload.text.trim();
    final body = <String, dynamic>{
      'license_number': _license.text.trim(),
      'vehicle_type': _vehicleType.text.trim(),
      'vehicle_number': _vehicleNumber.text.trim(),
      'payload_capacity_kg':
          payloadText.isEmpty ? null : double.parse(payloadText),
    };

    final result = await _putRiderField(
      context: context,
      path: '/rider/vehicle-details',
      body: body,
    );

    if (!mounted) return;
    setState(() => _isSubmitting = false);
    if (result != null) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return _SheetScaffold(
      title: 'Vehicle & License Info',
      subtitle:
          'Shown to farmers so they know what kind of vehicle to expect.',
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: _license,
              enabled: !_isSubmitting,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Driving License Number',
                hintText: 'e.g. KA0120190001234',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.badge_outlined),
              ),
            ),
            const SizedBox(height: 14),

            TextFormField(
              controller: _vehicleType,
              enabled: !_isSubmitting,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Vehicle Model',
                hintText: 'e.g. Tata Ace / Bolero Pickup',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.local_shipping_outlined),
              ),
            ),
            const SizedBox(height: 14),

            TextFormField(
              controller: _vehicleNumber,
              enabled: !_isSubmitting,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Vehicle Plate Number',
                hintText: 'e.g. KA01AB1234',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.directions_car_outlined),
              ),
            ),
            const SizedBox(height: 14),

            TextFormField(
              controller: _payload,
              enabled: !_isSubmitting,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              decoration: const InputDecoration(
                labelText: 'Max Payload Capacity',
                hintText: 'e.g. 750',
                helperText: 'Total weight your vehicle can safely carry',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.scale_outlined),
                suffixText: 'kg',
              ),
              validator: (v) {
                final value = (v ?? '').trim();
                if (value.isEmpty) return null; // optional
                final parsed = double.tryParse(value);
                if (parsed == null || parsed < 0) {
                  return 'Enter a valid non-negative number';
                }
                return null;
              },
            ),
            const SizedBox(height: 22),

            _SheetSubmitButton(
              label: 'SAVE VEHICLE DETAILS',
              isSubmitting: _isSubmitting,
              onPressed: _submit,
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// Sheet 2 — Operating Districts & Routes
// ============================================================================

class _RoutesSheet extends StatefulWidget {
  const _RoutesSheet({required this.account});

  final Map<String, dynamic>? account;

  @override
  State<_RoutesSheet> createState() => _RoutesSheetState();
}

class _RoutesSheetState extends State<_RoutesSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _routes;

  bool _isSubmitting = false;

  /// Short list of well-connected Karnataka districts surfaced as quick
  /// chips. Tapping one appends it to the comma-separated text field —
  /// saves typing on mobile keyboards, which is where most riders use this.
  static const List<String> _commonDistricts = [
    'Kolar',
    'Bengaluru Urban',
    'Bengaluru Rural',
    'Tumakuru',
    'Mandya',
    'Mysuru',
    'Chikkaballapura',
    'Ramanagara',
    'Hassan',
    'Davanagere',
  ];

  @override
  void initState() {
    super.initState();
    final a = widget.account ?? const {};
    _routes =
        TextEditingController(text: (a['operating_routes'] ?? '').toString());
  }

  @override
  void dispose() {
    _routes.dispose();
    super.dispose();
  }

  /// Append a district to the current value if not already present.
  void _appendDistrict(String d) {
    final current = _routes.text
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (current.any((s) => s.toLowerCase() == d.toLowerCase())) return;
    current.add(d);
    setState(() => _routes.text = current.join(', '));
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSubmitting = true);

    final body = <String, dynamic>{
      'operating_routes': _routes.text.trim(),
    };

    final result = await _putRiderField(
      context: context,
      path: '/rider/routes',
      body: body,
    );

    if (!mounted) return;
    setState(() => _isSubmitting = false);
    if (result != null) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return _SheetScaffold(
      title: 'Operating Districts & Routes',
      subtitle:
          'You will only see trips that start in these districts. Leave '
          'blank to see everything.',
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: _routes,
              enabled: !_isSubmitting,
              maxLines: 2,
              minLines: 2,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Operating Districts / Routes',
                hintText: 'e.g. Kolar, Bengaluru Urban, Tumakuru',
                helperText: 'Separate multiple districts with commas',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 18),

            Text(
              'Quick add',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: _commonDistricts
                  .map(
                    (d) => ActionChip(
                      label: Text(d, style: const TextStyle(fontSize: 12.5)),
                      onPressed:
                          _isSubmitting ? null : () => _appendDistrict(d),
                      backgroundColor: kRiderGreen.withOpacity(0.08),
                      side: BorderSide(
                        color: kRiderGreen.withOpacity(0.3),
                      ),
                      labelStyle: const TextStyle(color: kRiderGreen),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 22),

            _SheetSubmitButton(
              label: 'SAVE ROUTES',
              isSubmitting: _isSubmitting,
              onPressed: _submit,
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// Sheet 3 — Payout Details
// ============================================================================

class _PayoutDetailsSheet extends StatefulWidget {
  const _PayoutDetailsSheet({required this.account});

  final Map<String, dynamic>? account;

  @override
  State<_PayoutDetailsSheet> createState() => _PayoutDetailsSheetState();
}

class _PayoutDetailsSheetState extends State<_PayoutDetailsSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _bankName;
  late final TextEditingController _accountNumber;
  late final TextEditingController _ifsc;
  late final TextEditingController _upiId;

  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    final a = widget.account ?? const {};
    _bankName = TextEditingController(text: (a['bank_name'] ?? '').toString());
    _accountNumber = TextEditingController(
      text: (a['account_number'] ?? '').toString(),
    );
    _ifsc = TextEditingController(text: (a['ifsc_code'] ?? '').toString());
    _upiId = TextEditingController(text: (a['upi_id'] ?? '').toString());
  }

  @override
  void dispose() {
    _bankName.dispose();
    _accountNumber.dispose();
    _ifsc.dispose();
    _upiId.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSubmitting = true);

    final body = <String, dynamic>{
      'bank_name': _bankName.text.trim(),
      'account_number': _accountNumber.text.trim(),
      'ifsc_code': _ifsc.text.trim(),
      'upi_id': _upiId.text.trim(),
    };

    final result = await _putRiderField(
      context: context,
      path: '/rider/payouts',
      body: body,
    );

    if (!mounted) return;
    setState(() => _isSubmitting = false);
    if (result != null) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return _SheetScaffold(
      title: 'Payout Details',
      subtitle:
          'Where your trip earnings are settled. Either bank or UPI is '
          'enough.',
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: _bankName,
              enabled: !_isSubmitting,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Bank Name',
                hintText: 'e.g. State Bank of India',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.account_balance_outlined),
              ),
            ),
            const SizedBox(height: 14),

            TextFormField(
              controller: _accountNumber,
              enabled: !_isSubmitting,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(30),
              ],
              decoration: const InputDecoration(
                labelText: 'Account Number',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.numbers_outlined),
              ),
            ),
            const SizedBox(height: 14),

            TextFormField(
              controller: _ifsc,
              enabled: !_isSubmitting,
              textCapitalization: TextCapitalization.characters,
              inputFormatters: [
                LengthLimitingTextInputFormatter(11),
                FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
              ],
              decoration: const InputDecoration(
                labelText: 'IFSC Code',
                hintText: 'e.g. SBIN0001234',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.tag_outlined),
              ),
            ),
            const SizedBox(height: 14),

            TextFormField(
              controller: _upiId,
              enabled: !_isSubmitting,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'UPI ID (optional)',
                hintText: 'e.g. name@okicici',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.qr_code_2_outlined),
              ),
            ),
            const SizedBox(height: 22),

            _SheetSubmitButton(
              label: 'SAVE PAYOUT DETAILS',
              isSubmitting: _isSubmitting,
              onPressed: _submit,
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// Sheet 4 — Language Picker
// ============================================================================

class _LanguagePickerSheet extends StatelessWidget {
  const _LanguagePickerSheet({
    required this.current,
    required this.onSelected,
  });

  final String current;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return _SheetScaffold(
      title: 'App Language',
      subtitle: 'Choose the language used across KisanRider.',
      child: Column(
        children: [
          _LanguageOption(
            code: 'en',
            label: 'English',
            nativeLabel: 'English',
            selected: current == 'en',
            onTap: () {
              Navigator.of(context).pop();
              onSelected('en');
            },
          ),
          const SizedBox(height: 8),
          _LanguageOption(
            code: 'kn',
            label: 'Kannada',
            nativeLabel: 'ಕನ್ನಡ',
            selected: current == 'kn',
            onTap: () {
              Navigator.of(context).pop();
              onSelected('kn');
            },
          ),
        ],
      ),
    );
  }
}

class _LanguageOption extends StatelessWidget {
  const _LanguageOption({
    required this.code,
    required this.label,
    required this.nativeLabel,
    required this.selected,
    required this.onTap,
  });

  final String code;
  final String label;
  final String nativeLabel;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? kRiderGreen : Colors.grey.shade300,
            width: selected ? 1.6 : 1,
          ),
          color: selected ? kRiderGreen.withOpacity(0.06) : null,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14.5,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    nativeLabel,
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.grey.shade700,
                    ),
                  ),
                ],
              ),
            ),
            if (selected)
              const Icon(Icons.check_circle, color: kRiderGreen),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// Sheet 5 — Change Password (OTP flow)
// ============================================================================

class _ChangePasswordSheet extends StatefulWidget {
  const _ChangePasswordSheet({required this.email});

  final String email;

  @override
  State<_ChangePasswordSheet> createState() => _ChangePasswordSheetState();
}

class _ChangePasswordSheetState extends State<_ChangePasswordSheet> {
  static const int _stepRequest = 0;
  static const int _stepReset = 1;

  final _resetFormKey = GlobalKey<FormState>();
  final _otpController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  int _step = _stepRequest;
  bool _isSubmitting = false;
  bool _obscureNew = true;
  bool _obscureConfirm = true;

  @override
  void dispose() {
    _otpController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.red.shade700,
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  Future<void> _sendOtp() async {
    if (widget.email.isEmpty) {
      _showError('No email on file. Please contact support.');
      return;
    }
    setState(() => _isSubmitting = true);

    try {
      final response = await http.post(
        Uri.parse('$kApiBaseUrl/auth/forgot-password'),
        headers: const {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'email': widget.email}),
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        setState(() {
          _isSubmitting = false;
          _step = _stepReset;
        });
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text('OTP sent to ${widget.email}'),
              backgroundColor: kRiderGreen,
            ),
          );
      } else {
        setState(() => _isSubmitting = false);
        String message = 'Could not send OTP (HTTP ${response.statusCode}).';
        try {
          final decoded = jsonDecode(response.body);
          if (decoded is Map && decoded['detail'] != null) {
            message = decoded['detail'].toString();
          }
        } catch (_) {}
        if (mounted) _showError(message);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      _showError('Network error: $e');
    }
  }

  Future<void> _resetPassword() async {
    if (!_resetFormKey.currentState!.validate()) return;
    setState(() => _isSubmitting = true);

    try {
      final response = await http.post(
        Uri.parse('$kApiBaseUrl/auth/reset-password'),
        headers: const {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'email': widget.email,
          'otp': _otpController.text.trim(),
          'new_password': _newPasswordController.text,
        }),
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        Navigator.of(context).pop(true);
      } else {
        setState(() => _isSubmitting = false);
        String message =
            'Password change failed (HTTP ${response.statusCode}).';
        try {
          final decoded = jsonDecode(response.body);
          if (decoded is Map && decoded['detail'] != null) {
            message = decoded['detail'].toString();
          }
        } catch (_) {}
        if (mounted) _showError(message);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      _showError('Network error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SheetScaffold(
      title: 'Change Password',
      subtitle: _step == _stepRequest
          ? 'We will email a one-time code to confirm it is you.'
          : 'Enter the code we sent and choose a new password.',
      child: AnimatedSize(
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 240),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          child: _step == _stepRequest
              ? _buildRequestStep()
              : _buildResetStep(),
        ),
      ),
    );
  }

  Widget _buildRequestStep() {
    return Column(
      key: const ValueKey('pw_step_request'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: kRiderGreen.withOpacity(0.06),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: kRiderGreen.withOpacity(0.20)),
          ),
          child: Row(
            children: [
              const Icon(Icons.email_outlined, color: kRiderGreen, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.email.isEmpty ? 'No email on file' : widget.email,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        _SheetSubmitButton(
          label: 'SEND OTP',
          isSubmitting: _isSubmitting,
          onPressed: _sendOtp,
        ),
      ],
    );
  }

  Widget _buildResetStep() {
    return Form(
      key: _resetFormKey,
      child: Column(
        key: const ValueKey('pw_step_reset'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: _otpController,
            enabled: !_isSubmitting,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(4),
            ],
            decoration: const InputDecoration(
              labelText: '4-Digit OTP',
              hintText: '••••',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.password_rounded),
              counterText: '',
            ),
            validator: (v) {
              final value = (v ?? '').trim();
              if (!RegExp(r'^\d{4}$').hasMatch(value)) {
                return 'Enter the 4-digit code';
              }
              return null;
            },
          ),
          const SizedBox(height: 14),

          TextFormField(
            controller: _newPasswordController,
            enabled: !_isSubmitting,
            obscureText: _obscureNew,
            decoration: InputDecoration(
              labelText: 'New Password',
              hintText: 'At least 6 characters',
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.lock_outline),
              suffixIcon: IconButton(
                tooltip: _obscureNew ? 'Show' : 'Hide',
                icon: Icon(
                  _obscureNew
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
                onPressed: () => setState(() => _obscureNew = !_obscureNew),
              ),
            ),
            validator: (v) {
              final value = v ?? '';
              if (value.isEmpty) return 'New password is required';
              if (value.length < 6) return 'At least 6 characters';
              return null;
            },
          ),
          const SizedBox(height: 14),

          TextFormField(
            controller: _confirmPasswordController,
            enabled: !_isSubmitting,
            obscureText: _obscureConfirm,
            decoration: InputDecoration(
              labelText: 'Confirm New Password',
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.lock_reset_outlined),
              suffixIcon: IconButton(
                tooltip: _obscureConfirm ? 'Show' : 'Hide',
                icon: Icon(
                  _obscureConfirm
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
                onPressed: () =>
                    setState(() => _obscureConfirm = !_obscureConfirm),
              ),
            ),
            validator: (v) {
              final value = v ?? '';
              if (value.isEmpty) return 'Please confirm your new password';
              if (value != _newPasswordController.text) {
                return 'Passwords do not match';
              }
              return null;
            },
          ),
          const SizedBox(height: 22),

          _SheetSubmitButton(
            label: 'RESET PASSWORD',
            isSubmitting: _isSubmitting,
            onPressed: _resetPassword,
          ),
        ],
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
              'Could not load account',
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