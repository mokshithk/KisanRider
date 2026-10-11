import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;   // <-- ADD THIS LINE
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import 'login_screen.dart';

/// Base URL of the FastAPI backend.
///
/// - Web/Chrome uses `localhost`.
/// - Physical Android/iOS devices use your laptop's Wi-Fi IP.
String get _kApiBaseUrl {
  if (kIsWeb) return 'http://localhost:8000';
  return 'http://10.28.1.142:8000';
}

/// Kisan Green — the primary brand color used throughout the farmer UI.
const Color _kFarmerGreen = Color(0xFF2E7D32);

/// The Indian state this app currently serves. Shown in the header when
/// the user has no explicit district (fallback).
const String _kDefaultState = 'Karnataka';

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
/// **every** route in the Navigator, including the `MaterialApp.home`
/// route that hosted `_AuthGate`. So by the time the user taps Logout,
/// `_AuthGate` is no longer mounted and cannot react to
/// `notifyListeners()`. The only way back to the login screen is to replace
/// the stack explicitly — which is what this function does.
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
            backgroundColor: _kFarmerGreen,
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
// Farmer Account Screen
// ============================================================================

/// Body-only widget (no Scaffold / AppBar) designed to be embedded as the
/// Account tab of [FarmerDashboard]'s [IndexedStack]. The dashboard's own
/// AppBar provides the surrounding chrome.
///
/// On mount, fetches `GET /farmer/account` to populate every field. The
/// profile header renders instantly from [AuthProvider] and upgrades to
/// the fetched values once they arrive — the user sees their name on the
/// very first frame instead of a spinner.
class FarmerAccountScreen extends StatefulWidget {
  const FarmerAccountScreen({super.key});

  @override
  State<FarmerAccountScreen> createState() => _FarmerAccountScreenState();
}

class _FarmerAccountScreenState extends State<FarmerAccountScreen>
    with AutomaticKeepAliveClientMixin {
  Map<String, dynamic>? _account;
  bool _isLoading = true;
  String? _error;

  /// Local mirror of `preferred_language` so the picker has something to
  /// render immediately. Once the backend's `FarmerProfileUpdate` gains
  /// that field, swap the local assignment in [_onLanguageSelected] for a
  /// PUT and this can be deleted.
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

  Map<String, String> _headers(AuthProvider auth) => {
        'Authorization': 'Bearer ${auth.token}',
        'Accept': 'application/json',
      };

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
        Uri.parse('$_kApiBaseUrl/farmer/account'),
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

  // -------------------------------------------------------------------------
  // Field accessors — prefer fetched account, fall back to AuthProvider
  // -------------------------------------------------------------------------

  String get _displayName {
    final fromAccount = _account?['full_name']?.toString() ?? '';
    if (fromAccount.isNotEmpty) return fromAccount;
    final fromAuth = context.read<AuthProvider>().fullName ?? '';
    return fromAuth.isEmpty ? 'Farmer' : fromAuth;
  }

  String get _displayEmail {
    final fromAccount = _account?['email']?.toString() ?? '';
    if (fromAccount.isNotEmpty) return fromAccount;
    return context.read<AuthProvider>().email ?? '';
  }

  String get _displayDistrict {
    final fromAccount = _account?['district']?.toString() ?? '';
    if (fromAccount.isNotEmpty) return fromAccount;
    final fromAuth = context.read<AuthProvider>().district ?? '';
    return fromAuth;
  }

  String get _displayRole {
    final fromAccount = _account?['role']?.toString() ?? '';
    if (fromAccount.isNotEmpty) return fromAccount;
    return context.read<AuthProvider>().role ?? 'FARMER';
  }

  /// Contact phone number, as normalized by the backend (10 digits, no
  /// country code). Empty string when unset — the header uses that to
  /// decide whether to render the phone row at all.
  String get _displayPhone {
    return _account?['phone_number']?.toString() ?? '';
  }

  // -------------------------------------------------------------------------
  // Sheet launchers — each awaits a `true` result then refetches
  // -------------------------------------------------------------------------

  Future<void> _openSheet(Widget sheet) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => sheet,
    );
    if (changed == true && mounted) {
      _showSuccess('Saved successfully.');
      await _fetchAccount();
    }
  }

  void _showSuccess(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: _kFarmerGreen,
        ),
      );
  }

  Future<void> _onLanguageSelected(String code) async {
    // Local-only for now — see class-level comment on `_preferredLanguage`.
    setState(() => _preferredLanguage = code);
    if (!mounted) return;
    _showSuccess(
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
      color: _kFarmerGreen,
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
              phoneNumber: _displayPhone,
            ),
            const SizedBox(height: 8),

            // ----- Personal Information ---------------------------------
            _SectionHeader(title: 'PERSONAL INFORMATION'),
            _SettingsCard(
              children: [
                _SettingsTile(
                  icon: Icons.person_outline,
                  title: 'Edit Profile',
                  subtitle: 'Name, phone, district & taluk',
                  onTap: () => _openSheet(
                    _EditProfileSheet(account: _account),
                  ),
                ),
                const Divider(height: 1, indent: 56),
                _SettingsTile(
                  icon: Icons.agriculture_outlined,
                  title: 'Farm Details',
                  subtitle: 'Farm size and primary crops',
                  onTap: () => _openSheet(
                    _FarmDetailsSheet(account: _account),
                  ),
                ),
              ],
            ),

            // ----- Locations & Addresses --------------------------------
            _SectionHeader(title: 'LOCATIONS & ADDRESSES'),
            _SettingsCard(
              children: [
                _SettingsTile(
                  icon: Icons.location_on_outlined,
                  title: 'Saved Farm Addresses',
                  subtitle: 'Pickup address and landmark for riders',
                  onTap: () => _openSheet(
                    _FarmAddressSheet(account: _account),
                  ),
                ),
              ],
            ),

            // ----- Payouts & Banking ------------------------------------
            _SectionHeader(title: 'PAYOUTS & BANKING'),
            _SettingsCard(
              children: [
                _SettingsTile(
                  icon: Icons.account_balance_outlined,
                  title: 'Bank Account & UPI Details',
                  subtitle: 'Where your payouts are credited',
                  onTap: () => _openSheet(
                    _PayoutDetailsSheet(account: _account),
                  ),
                ),
              ],
            ),

            // ----- Preferences & Security -------------------------------
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

            // ----- Support & Legal --------------------------------------
            _SectionHeader(title: 'SUPPORT & LEGAL'),
            _SettingsCard(
              children: [
                _SettingsTile(
                  icon: Icons.headset_mic_outlined,
                  title: 'Help & Support',
                  onTap: () => _showInfoDialog(
                    context,
                    title: 'Help & Support',
                    body: 'Need a hand?\n\n'
                        'Email: support@kisanrider.app\n'
                        'Phone: +91 1800 000 000\n'
                        'Hours: Mon–Sat, 9 AM to 6 PM IST\n\n'
                        'For urgent issues with an active trip, please '
                        'call the rider directly from the My Orders tab.',
                  ),
                ),
                const Divider(height: 1, indent: 56),
                _SettingsTile(
                  icon: Icons.description_outlined,
                  title: 'Terms & Privacy Policy',
                  onTap: () => _showInfoDialog(
                    context,
                    title: 'Terms & Privacy Policy',
                    body: 'KisanRider connects farmers and riders for '
                        'agricultural transport across Karnataka.\n\n'
                        'We collect only what is necessary to operate the '
                        'service: your name, contact details, farm location, '
                        'and payout information. Location data is used to '
                        'match produce requests with nearby riders and is '
                        'never shared with third parties.\n\n'
                        'By continuing to use KisanRider you agree to these '
                        'terms and to our privacy practices.',
                  ),
                ),
              ],
            ),

            const SizedBox(height: 32),

            // ----- Logout ------------------------------------------------
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
              icon: const Icon(Icons.power_settings_new_rounded),
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
            style: TextButton.styleFrom(foregroundColor: _kFarmerGreen),
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
    required this.phoneNumber,
  });

  final String fullName;
  final String email;
  final String district;
  final String role;

  /// Normalized 10-digit contact number, or empty string when unset.
  /// When empty, the phone row is omitted entirely — the Edit Profile
  /// tile is the discoverable way to add one.
  final String phoneNumber;

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
            _kFarmerGreen.withOpacity(0.12),
            _kFarmerGreen.withOpacity(0.03),
          ],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _kFarmerGreen.withOpacity(0.25)),
      ),
      child: Column(
        children: [
          // Avatar
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: _kFarmerGreen.withOpacity(0.15),
              shape: BoxShape.circle,
              border: Border.all(
                color: _kFarmerGreen.withOpacity(0.5),
                width: 2,
              ),
            ),
            child: const Icon(
              Icons.person,
              size: 48,
              color: _kFarmerGreen,
            ),
          ),
          const SizedBox(height: 16),

          // Name
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

          // Email
          Text(
            email.isEmpty ? '—' : email,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),

          // Contact phone (only rendered when a number is on file).
          // Prefixed with "+91 " so the displayed value matches what a
          // user would dial — the stored value is just the 10 digits.
          if (phoneNumber.isNotEmpty) ...[
            const SizedBox(height: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.phone,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(
                  '+91 $phoneNumber',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],

          const SizedBox(height: 14),

          // Pill chips
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              _PillChip(
                icon: Icons.location_on_outlined,
                label: district.isEmpty
                    ? 'District: $_kDefaultState'
                    : 'District: $district',
                foreground: Colors.grey.shade800,
                background: Colors.white,
                border: Colors.grey.shade300,
              ),
              _PillChip(
                icon: Icons.verified_user_outlined,
                label: 'Role: $role',
                foreground: _kFarmerGreen,
                background: _kFarmerGreen.withOpacity(0.15),
                border: _kFarmerGreen.withOpacity(0.5),
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
      leading: Icon(icon, color: _kFarmerGreen),
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
// Bottom sheet base layout (shared chrome for every modal)
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
                    color: _kFarmerGreen,
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

/// Shared submit button — same shape across every modal.
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
        backgroundColor: _kFarmerGreen,
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

/// Surface the backend's `detail` in a red SnackBar. Falls back to a
/// caller-supplied message on any non-Dio or non-`detail` shape.
void _showRedSnack(BuildContext context, String message) {
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

// ============================================================================
// PUT helper — every modal hits a different endpoint with the same shape
// ============================================================================

/// Sends a PUT to [path] with [body] and returns the decoded response map
/// on success. Returns null on failure and surfaces the error via SnackBar.
Future<Map<String, dynamic>?> _putAccountField({
  required BuildContext context,
  required String path,
  required Map<String, dynamic> body,
}) async {
  final auth = context.read<AuthProvider>();
  if (auth.token == null) {
    _showRedSnack(context, 'Not signed in.');
    return null;
  }

  try {
    final response = await http.put(
      Uri.parse('$_kApiBaseUrl$path'),
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

    // Extract backend detail.
    String message = 'Save failed (HTTP ${response.statusCode}).';
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['detail'] != null) {
        message = decoded['detail'].toString();
      }
    } catch (_) {}
    if (context.mounted) _showRedSnack(context, message);
    return null;
  } catch (e) {
    if (context.mounted) {
      _showRedSnack(context, 'Network error: $e');
    }
    return null;
  }
}

// ============================================================================
// Sheet 1 — Edit Profile (name, phone, district, taluk/village)
// ============================================================================

class _EditProfileSheet extends StatefulWidget {
  const _EditProfileSheet({required this.account});

  final Map<String, dynamic>? account;

  @override
  State<_EditProfileSheet> createState() => _EditProfileSheetState();
}

class _EditProfileSheetState extends State<_EditProfileSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _fullName;
  late final TextEditingController _talukVillage;

  /// Holds the 10-digit number without any prefix. The "+91 " shown in
  /// the field is a `prefixText` decoration, not part of the value — that
  /// way the same controller round-trips cleanly through the backend
  /// (which stores exactly the 10 digits).
  late final TextEditingController _phone;

  String? _district;

  bool _isSubmitting = false;

  /// Same list used by the Book Transport form, so the two dropdowns stay
  /// in sync without a shared constants file.
  static const List<String> _districts = [
    'Bagalkot', 'Ballari', 'Belagavi', 'Bengaluru Rural', 'Bengaluru Urban',
    'Bidar', 'Chamarajanagar', 'Chikkaballapura', 'Chikkamagaluru',
    'Chitradurga', 'Dakshina Kannada', 'Davanagere', 'Dharwad', 'Gadag',
    'Hassan', 'Haveri', 'Kalaburagi', 'Kodagu', 'Kolar', 'Koppal', 'Mandya',
    'Mysuru', 'Raichur', 'Ramanagara', 'Shivamogga', 'Tumakuru', 'Udupi',
    'Uttara Kannada', 'Vijayapura', 'Yadgir', 'Vijayanagara',
  ];

  @override
  void initState() {
    super.initState();
    final a = widget.account ?? const {};
    _fullName = TextEditingController(text: (a['full_name'] ?? '').toString());
    _talukVillage =
        TextEditingController(text: (a['taluk_village'] ?? '').toString());

    // Strip any non-digit characters defensively — the backend normalizes
    // on write, but a value that predates that validation might still be
    // sitting in the DB. The digits-only formatter on the field would
    // silently drop them anyway; doing it here means the initial render
    // is consistent with what the user can subsequently type.
    final rawPhone = (a['phone_number'] ?? '').toString();
    _phone = TextEditingController(
      text: rawPhone.replaceAll(RegExp(r'\D'), ''),
    );

    final d = (a['district'] ?? '').toString();
    _district = _districts.contains(d) ? d : null;
  }

  @override
  void dispose() {
    _fullName.dispose();
    _talukVillage.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSubmitting = true);

    final phoneText = _phone.text.trim();

    final body = <String, dynamic>{
      'full_name': _fullName.text.trim(),
      'district': _district,
      'taluk_village': _talukVillage.text.trim(),
      // Empty string clears the field server-side (PhoneNumber validator
      // returns None for empty input). Non-empty has already been shaped
      // to 10 digits by the input formatter + validator.
      'phone_number': phoneText.isEmpty ? '' : phoneText,
    };

    final result = await _putAccountField(
      context: context,
      path: '/farmer/profile',
      body: body,
    );

    if (!mounted) return;
    setState(() => _isSubmitting = false);
    if (result != null) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return _SheetScaffold(
      title: 'Edit Profile',
      subtitle: 'Your name and contact details as they appear to riders.',
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: _fullName,
              enabled: !_isSubmitting,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Full Name',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.person_outline),
              ),
              validator: (v) {
                if ((v ?? '').trim().isEmpty) return 'Name is required';
                return null;
              },
            ),
            const SizedBox(height: 14),

            // Contact phone number. The "+91 " prefix is decoration; the
            // controller value is just the 10 digits. inputFormatters
            // enforce digits-only + max length so the field can't produce
            // a value the validator would reject on shape grounds.
            TextFormField(
              controller: _phone,
              enabled: !_isSubmitting,
              keyboardType: TextInputType.phone,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(10),
              ],
              decoration: const InputDecoration(
                labelText: 'Contact Phone Number',
                hintText: '9876543210',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.phone),
                prefixText: '+91 ',
                helperText:
                    'Shared with your rider on active trips',
              ),
              validator: (v) {
                final value = (v ?? '').trim();
                // Optional field — a farmer who doesn't want to share a
                // number can leave it blank.
                if (value.isEmpty) return null;
                if (!RegExp(r'^\d{10}$').hasMatch(value)) {
                  return 'Enter a valid 10-digit mobile number';
                }
                return null;
              },
            ),
            const SizedBox(height: 14),

            // Email is intentionally read-only: changing it is a privileged
            // operation that would need re-verification. Shown so the user
            // sees which address their OTPs go to.
            TextFormField(
              initialValue: (widget.account?['email'] ?? '').toString(),
              enabled: false,
              decoration: const InputDecoration(
                labelText: 'Email Address',
                helperText: 'Contact support to change your login email',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.email_outlined),
                filled: true,
              ),
            ),
            const SizedBox(height: 14),

            DropdownButtonFormField<String>(
              value: _district,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'District',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.map_outlined),
              ),
              items: _districts
                  .map((d) => DropdownMenuItem<String>(
                        value: d,
                        child: Text(d, overflow: TextOverflow.ellipsis),
                      ))
                  .toList(),
              onChanged: _isSubmitting
                  ? null
                  : (v) => setState(() => _district = v),
            ),
            const SizedBox(height: 14),

            TextFormField(
              controller: _talukVillage,
              enabled: !_isSubmitting,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Taluk / Village',
                hintText: 'e.g. Bangarpet, Kolar',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.holiday_village_outlined),
              ),
            ),
            const SizedBox(height: 22),

            _SheetSubmitButton(
              label: 'SAVE PROFILE',
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
// Sheet 2 — Farm Details (size + primary crops)
// ============================================================================

class _FarmDetailsSheet extends StatefulWidget {
  const _FarmDetailsSheet({required this.account});

  final Map<String, dynamic>? account;

  @override
  State<_FarmDetailsSheet> createState() => _FarmDetailsSheetState();
}

class _FarmDetailsSheetState extends State<_FarmDetailsSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _farmSize;
  late final TextEditingController _primaryCrops;

  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    final a = widget.account ?? const {};
    final size = a['farm_size_acres'];
    _farmSize = TextEditingController(
      text: size == null ? '' : size.toString(),
    );
    _primaryCrops =
        TextEditingController(text: (a['primary_crops'] ?? '').toString());
  }

  @override
  void dispose() {
    _farmSize.dispose();
    _primaryCrops.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSubmitting = true);

    final sizeText = _farmSize.text.trim();
    final body = <String, dynamic>{
      'farm_size_acres': sizeText.isEmpty ? null : double.parse(sizeText),
      'primary_crops': _primaryCrops.text.trim(),
    };

    final result = await _putAccountField(
      context: context,
      path: '/farmer/farm-details',
      body: body,
    );

    if (!mounted) return;
    setState(() => _isSubmitting = false);
    if (result != null) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return _SheetScaffold(
      title: 'Farm Details',
      subtitle: 'Used to estimate loading and crop planning.',
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: _farmSize,
              enabled: !_isSubmitting,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              decoration: const InputDecoration(
                labelText: 'Farm Size (acres)',
                hintText: 'e.g. 3.5',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.square_foot_outlined),
                suffixText: 'acres',
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
            const SizedBox(height: 14),

            TextFormField(
              controller: _primaryCrops,
              enabled: !_isSubmitting,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Primary Crops',
                hintText: 'e.g. Tomatoes, Beans, Ragi',
                helperText: 'Separate multiple crops with commas',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.eco_outlined),
              ),
            ),
            const SizedBox(height: 22),

            _SheetSubmitButton(
              label: 'SAVE FARM DETAILS',
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
// Sheet 3 — Farm Address (pickup address + landmark)
// ============================================================================

class _FarmAddressSheet extends StatefulWidget {
  const _FarmAddressSheet({required this.account});

  final Map<String, dynamic>? account;

  @override
  State<_FarmAddressSheet> createState() => _FarmAddressSheetState();
}

class _FarmAddressSheetState extends State<_FarmAddressSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _farmAddress;
  late final TextEditingController _landmark;

  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    final a = widget.account ?? const {};
    _farmAddress =
        TextEditingController(text: (a['farm_address'] ?? '').toString());
    _landmark = TextEditingController(text: (a['landmark'] ?? '').toString());
  }

  @override
  void dispose() {
    _farmAddress.dispose();
    _landmark.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSubmitting = true);

    final body = <String, dynamic>{
      'farm_address': _farmAddress.text.trim(),
      'landmark': _landmark.text.trim(),
    };

    final result = await _putAccountField(
      context: context,
      path: '/farmer/address',
      body: body,
    );

    if (!mounted) return;
    setState(() => _isSubmitting = false);
    if (result != null) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return _SheetScaffold(
      title: 'Farm Pickup Address',
      subtitle:
          'Riders use this to find your farm. Be as specific as you can.',
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: _farmAddress,
              enabled: !_isSubmitting,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Farm Address',
                hintText:
                    'Survey no., village, post office, taluk, district, PIN',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 14),

            TextFormField(
              controller: _landmark,
              enabled: !_isSubmitting,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Nearby Landmark',
                hintText: 'e.g. Opposite the water tank, near the school',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.signpost_outlined),
              ),
            ),
            const SizedBox(height: 22),

            _SheetSubmitButton(
              label: 'SAVE ADDRESS',
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
// Sheet 4 — Payout Details (bank + UPI)
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

    final result = await _putAccountField(
      context: context,
      path: '/farmer/payouts',
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
          'Where settlements are credited. Either bank or UPI is enough.',
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
// Sheet 5 — Language Picker
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
            color: selected ? _kFarmerGreen : Colors.grey.shade300,
            width: selected ? 1.6 : 1,
          ),
          color: selected ? _kFarmerGreen.withOpacity(0.06) : null,
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
              const Icon(Icons.check_circle, color: _kFarmerGreen),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// Sheet 6 — Change Password (OTP flow, reuses /auth/forgot-password)
// ============================================================================

class _ChangePasswordSheet extends StatefulWidget {
  const _ChangePasswordSheet({required this.email});

  /// Pre-filled from the account screen. Shown read-only in step 1 so the
  /// user knows where the OTP will land.
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

  Future<void> _sendOtp() async {
    if (widget.email.isEmpty) {
      _showRedSnack(context, 'No email on file. Please contact support.');
      return;
    }
    setState(() => _isSubmitting = true);

    try {
      final response = await http.post(
        Uri.parse('$_kApiBaseUrl/auth/forgot-password'),
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
              backgroundColor: _kFarmerGreen,
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
        if (mounted) _showRedSnack(context, message);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      _showRedSnack(context, 'Network error: $e');
    }
  }

  Future<void> _resetPassword() async {
    if (!_resetFormKey.currentState!.validate()) return;
    setState(() => _isSubmitting = true);

    try {
      final response = await http.post(
        Uri.parse('$_kApiBaseUrl/auth/reset-password'),
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
        String message = 'Password change failed (HTTP ${response.statusCode}).';
        try {
          final decoded = jsonDecode(response.body);
          if (decoded is Map && decoded['detail'] != null) {
            message = decoded['detail'].toString();
          }
        } catch (_) {}
        if (mounted) _showRedSnack(context, message);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      _showRedSnack(context, 'Network error: $e');
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
            color: _kFarmerGreen.withOpacity(0.06),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _kFarmerGreen.withOpacity(0.20)),
          ),
          child: Row(
            children: [
              const Icon(Icons.email_outlined,
                  color: _kFarmerGreen, size: 20),
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