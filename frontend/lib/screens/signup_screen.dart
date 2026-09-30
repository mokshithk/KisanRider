import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import 'farmer_dashboard.dart';
import 'rider_dashboard.dart';

/// Base URL of the FastAPI backend.
///
/// NOTE: `127.0.0.1` only works from Flutter Desktop / Chrome on the same
/// machine. On an Android emulator use `10.0.2.2`, on a physical device use
/// your machine's LAN IP.
const String _kApiBaseUrl = 'http://127.0.0.1:8000';

/// Brand green, matching the rest of the app.
const Color _kBrandGreen = Color(0xFF2E7D32);

/// Timeout for both signup and OTP-verify calls. Long enough to survive a
/// slow SMTP handshake on the backend, short enough that a hung connection
/// doesn't leave a spinner spinning forever.
const Duration _kApiTimeout = Duration(seconds: 20);

/// All 31 Karnataka districts.
///
/// The KEY is what the user sees in the dropdown — the parenthetical form
/// with the common English transliteration (e.g. "Ballari (Bellary)").
/// The VALUE is the canonical spelling the FastAPI backend stores and
/// matches against (`_DISTRICT_CENTERS` in main.py). Keeping both in one
/// map means the UI can show a friendly label without ever sending a
/// string the backend can't match — that mismatch would silently break
/// the mandi picker and rates selector downstream.
const Map<String, String> _kKarnatakaDistricts = {
  'Bagalkote':             'Bagalkot',
  'Ballari (Bellary)':     'Ballari',
  'Belagavi (Belgaum)':    'Belagavi',
  'Bengaluru Rural':       'Bengaluru Rural',
  'Bengaluru Urban':       'Bengaluru Urban',
  'Bidar':                 'Bidar',
  'Chamarajanagara':       'Chamarajanagar',
  'Chikkaballapura':       'Chikkaballapura',
  'Chikkamagaluru':        'Chikkamagaluru',
  'Chitradurga':           'Chitradurga',
  'Dakshina Kannada':      'Dakshina Kannada',
  'Davanagere':            'Davanagere',
  'Dharwad':               'Dharwad',
  'Gadag':                 'Gadag',
  'Hassan':                'Hassan',
  'Haveri':                'Haveri',
  'Kalaburagi (Gulbarga)': 'Kalaburagi',
  'Kodagu':                'Kodagu',
  'Kolar':                 'Kolar',
  'Koppal':                'Koppal',
  'Mandya':                'Mandya',
  'Mysuru (Mysore)':       'Mysuru',
  'Raichur':               'Raichur',
  'Ramanagara':            'Ramanagara',
  'Shivamogga (Shimoga)':  'Shivamogga',
  'Tumakuru (Tumkur)':     'Tumakuru',
  'Udupi':                 'Udupi',
  'Uttara Kannada':        'Uttara Kannada',
  'Vijayanagara':          'Vijayanagara',
  'Vijayapura (Bijapur)':  'Vijayapura',
  'Yadgir':                'Yadgir',
};

/// Two-step signup: fill the form, tap VERIFY EMAIL & REGISTER, then enter
/// the 4-digit OTP emailed to the address. On success the JWT is persisted
/// via AuthProvider and the user is routed to their role's dashboard.
class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _formKey = GlobalKey<FormState>();

  final TextEditingController _fullNameController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  String? _selectedRole;
  String? _selectedDistrict; // display label (the Map key)
  bool _obscurePassword = true;
  bool _acceptedTerms = false;
  bool _isSubmitting = false;

  @override
  void dispose() {
    _fullNameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  Map<String, String> _headers({bool json = false}) {
    final h = <String, String>{'Accept': 'application/json'};
    if (json) h['Content-Type'] = 'application/json';
    return h;
  }

  /// Extracts FastAPI's `{"detail": "..."}` error string. Falls back to null
  /// so the caller can supply a generic message.
  String? _extractError(http.Response response) {
    try {
      final body = jsonDecode(response.body);
      if (body is Map && body['detail'] != null) {
        return body['detail'].toString();
      }
    } catch (_) {
      // Body wasn't JSON — nothing to extract.
    }
    return null;
  }

  void _showErrorSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red.shade700,
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Signup flow
  // -------------------------------------------------------------------------

  Future<void> _submitSignup() async {
    if (!_formKey.currentState!.validate()) return;

    if (!_acceptedTerms) {
      _showErrorSnack('Please accept the Terms & Conditions to continue.');
      return;
    }

    setState(() => _isSubmitting = true);

    // The exact payload we'll send to BOTH /auth/signup and (with `otp`
    // added) /auth/verify-otp. The backend's verify endpoint carries the
    // whole signup payload so the account can be created in one round-trip
    // after the OTP is confirmed.
    //
    // NOTE: `district` is looked up through the map so the dropdown can
    // display "Ballari (Bellary)" while the API receives "Ballari" — the
    // canonical key the FastAPI backend's _DISTRICT_CENTERS is keyed on.
    final payload = <String, String>{
      'full_name': _fullNameController.text.trim(),
      'email': _emailController.text.trim().toLowerCase(),
      'password': _passwordController.text,
      'role': _selectedRole!,
      'state': 'Karnataka',
      'district': _kKarnatakaDistricts[_selectedDistrict] ?? _selectedDistrict!,
    };

    try {
      final response = await http
          .post(
            Uri.parse('$_kApiBaseUrl/auth/signup'),
            headers: _headers(json: true),
            body: jsonEncode(payload),
          )
          .timeout(_kApiTimeout);

      if (!mounted) return;

      if (response.statusCode == 200 || response.statusCode == 201) {
        // Hand off to the OTP sheet. It returns the parsed verify-otp
        // response on success, or null if the user backed out.
        final verified = await _openOtpSheet(payload);
        if (verified != null) {
          await _completeSignup(verified);
        }
      } else {
        _showErrorSnack(
          _extractError(response) ??
              'Signup failed (HTTP ${response.statusCode}).',
        );
      }
    } on TimeoutException {
      _showErrorSnack(
        'Connection timed out. Please check your internet and try again.',
      );
    } catch (e) {
      _showErrorSnack('Network error: $e');
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  Future<Map<String, dynamic>?> _openOtpSheet(
    Map<String, String> signupPayload,
  ) {
    return showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      // Non-dismissible so the user can't accidentally lose their OTP
      // context by tapping outside. They can still cancel via the button.
      isDismissible: false,
      enableDrag: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _OtpBottomSheet(
        email: signupPayload['email']!,
        signupPayload: signupPayload,
      ),
    );
  }

  Future<void> _completeSignup(Map<String, dynamic> verifyResponse) async {
    final token = verifyResponse['access_token'] as String?;
    final user = verifyResponse['user'] as Map<String, dynamic>?;
    final role = (user?['role'] ?? _selectedRole ?? 'FARMER').toString();
    final userId = (user?['id'] ?? '').toString();

    if (token == null || token.isEmpty || userId.isEmpty) {
      _showErrorSnack('Server returned an incomplete session. Please retry.');
      return;
    }

    final auth = context.read<AuthProvider>();
    final ok = await auth.completeSignup(
      token: token,
      role: role,
      userId: userId,
    );
    if (!mounted) return;

    if (!ok) {
      _showErrorSnack(auth.lastError ?? 'Could not save session.');
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Account created successfully!'),
        backgroundColor: _kBrandGreen,
      ),
    );

    // Replace the whole nav stack so "back" doesn't return to signup.
    // NOTE: your project uses FarmerDashboard / RiderDashboard — the
    // earlier FarmerHomeScreen / RiderMainScreen names don't exist here.
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => role == 'RIDER'
            ? const RiderDashboard()
            : const FarmerDashboard(),
      ),
      (route) => false,
    );
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade50,
      appBar: AppBar(
        title: const Text('Sign Up'),
        backgroundColor: _kBrandGreen,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
          child: Card(
            elevation: 1,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 28, 20, 28),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildHeader(),
                    const SizedBox(height: 28),
                    _buildFullNameField(),
                    const SizedBox(height: 16),
                    _buildEmailField(),
                    const SizedBox(height: 16),
                    _buildPasswordField(),
                    const SizedBox(height: 16),
                    _buildRoleDropdown(),
                    const SizedBox(height: 16),
                    _buildStateField(),
                    const SizedBox(height: 16),
                    _buildDistrictDropdown(),
                    const SizedBox(height: 12),
                    _buildTermsCheckbox(),
                    const SizedBox(height: 24),
                    _buildSubmitButton(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: _kBrandGreen.withOpacity(0.08),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.agriculture_rounded,
            size: 44,
            color: _kBrandGreen,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Create KisanRider Account',
          textAlign: TextAlign.center,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Agricultural logistics, connected across Karnataka',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildFullNameField() {
    return TextFormField(
      controller: _fullNameController,
      enabled: !_isSubmitting,
      textCapitalization: TextCapitalization.words,
      decoration: const InputDecoration(
        labelText: 'Full Name',
        hintText: 'e.g. Ravi Kumar',
        border: OutlineInputBorder(),
        prefixIcon: Icon(Icons.person_outline),
      ),
      validator: (v) {
        if (v == null || v.trim().isEmpty) return 'Full name is required';
        if (v.trim().length < 2) return 'Name is too short';
        return null;
      },
    );
  }

  Widget _buildEmailField() {
    return TextFormField(
      controller: _emailController,
      enabled: !_isSubmitting,
      keyboardType: TextInputType.emailAddress,
      textInputAction: TextInputAction.next,
      autocorrect: false,
      decoration: const InputDecoration(
        labelText: 'Email Address',
        hintText: 'you@example.com',
        border: OutlineInputBorder(),
        prefixIcon: Icon(Icons.email_outlined),
      ),
      validator: (v) {
        final value = (v ?? '').trim();
        if (value.isEmpty) return 'Email is required';
        // Pragmatic email check — matches what the backend's EmailStr
        // accepts in the common case (one @, a dot after it, no spaces).
        // The backend runs its own validation; this is just for fast UX.
        final emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
        if (!emailRe.hasMatch(value)) return 'Enter a valid email address';
        return null;
      },
    );
  }

  Widget _buildPasswordField() {
    return TextFormField(
      controller: _passwordController,
      enabled: !_isSubmitting,
      obscureText: _obscurePassword,
      decoration: InputDecoration(
        labelText: 'Password',
        hintText: 'At least 6 characters',
        border: const OutlineInputBorder(),
        prefixIcon: const Icon(Icons.lock_outline),
        suffixIcon: IconButton(
          tooltip: _obscurePassword ? 'Show password' : 'Hide password',
          icon: Icon(
            _obscurePassword
                ? Icons.visibility_outlined
                : Icons.visibility_off_outlined,
          ),
          onPressed: () =>
              setState(() => _obscurePassword = !_obscurePassword),
        ),
      ),
      validator: (v) {
        final value = (v ?? '');
        if (value.isEmpty) return 'Password is required';
        if (value.length < 6) return 'Password must be at least 6 characters';
        return null;
      },
    );
  }

  Widget _buildRoleDropdown() {
    return DropdownButtonFormField<String>(
      value: _selectedRole,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'I am a',
        border: OutlineInputBorder(),
        prefixIcon: Icon(Icons.badge_outlined),
      ),
      items: const [
        DropdownMenuItem<String>(
          value: 'FARMER',
          child: Text('Farmer — I want to ship my produce'),
        ),
        DropdownMenuItem<String>(
          value: 'RIDER',
          child: Text('Rider — I want to transport produce'),
        ),
      ],
      onChanged: _isSubmitting
          ? null
          : (v) => setState(() => _selectedRole = v),
      validator: (v) => v == null ? 'Please select a role' : null,
    );
  }

  Widget _buildStateField() {
    // Locked to Karnataka for MVP. If this expands beyond one state, turn
    // it into a dropdown with the same pattern as District.
    return TextFormField(
      enabled: false,
      initialValue: 'Karnataka',
      decoration: const InputDecoration(
        labelText: 'State',
        border: OutlineInputBorder(),
        prefixIcon: Icon(Icons.map_outlined),
        helperText: 'Currently available only in Karnataka',
      ),
    );
  }

  Widget _buildDistrictDropdown() {
    // Display labels come from the Map keys (with parenthetical English
    // transliterations); the API value is resolved from the Map on submit.
    final labels = _kKarnatakaDistricts.keys.toList(growable: false);

    return DropdownButtonFormField<String>(
      value: _selectedDistrict,
      isExpanded: true,
      menuMaxHeight: 320,
      decoration: const InputDecoration(
        labelText: 'District',
        border: OutlineInputBorder(),
        prefixIcon: Icon(Icons.location_city_outlined),
      ),
      items: labels
          .map(
            (label) => DropdownMenuItem<String>(
              value: label,
              child: Text(label, overflow: TextOverflow.ellipsis),
            ),
          )
          .toList(),
      onChanged: _isSubmitting
          ? null
          : (v) => setState(() => _selectedDistrict = v),
      validator: (v) => v == null ? 'Please select your district' : null,
    );
  }

  Widget _buildTermsCheckbox() {
    final theme = Theme.of(context);
    return CheckboxListTile(
      value: _acceptedTerms,
      onChanged: _isSubmitting
          ? null
          : (v) => setState(() => _acceptedTerms = v ?? false),
      controlAffinity: ListTileControlAffinity.leading,
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(
        'I agree to the Terms & Conditions and Privacy Policy',
        style: theme.textTheme.bodySmall,
      ),
      activeColor: _kBrandGreen,
    );
  }

  Widget _buildSubmitButton() {
    return FilledButton.icon(
      onPressed: _isSubmitting ? null : _submitSignup,
      style: FilledButton.styleFrom(
        backgroundColor: _kBrandGreen,
        padding: const EdgeInsets.symmetric(vertical: 16),
        textStyle: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
      icon: _isSubmitting
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : const Icon(Icons.mark_email_read_outlined),
      label: Text(_isSubmitting ? 'Sending OTP…' : 'VERIFY EMAIL & REGISTER'),
    );
  }
}

// ---------------------------------------------------------------------------
// OTP bottom sheet
// ---------------------------------------------------------------------------

/// Modal sheet that collects the 4-digit OTP emailed to [email] and calls
/// `POST /auth/verify-otp`. Pops with the parsed response on success, or
/// null if the user cancels.
class _OtpBottomSheet extends StatefulWidget {
  const _OtpBottomSheet({
    required this.email,
    required this.signupPayload,
  });

  final String email;
  final Map<String, String> signupPayload;

  @override
  State<_OtpBottomSheet> createState() => _OtpBottomSheetState();
}

class _OtpBottomSheetState extends State<_OtpBottomSheet> {
  final _formKey = GlobalKey<FormState>();
  final _otpController = TextEditingController();
  bool _isVerifying = false;
  String? _error;

  @override
  void dispose() {
    _otpController.dispose();
    super.dispose();
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

  Future<void> _verify() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isVerifying = true;
      _error = null;
    });

    Map<String, dynamic>? successPayload;

    try {
      final body = Map<String, String>.from(widget.signupPayload)
        ..['otp'] = _otpController.text.trim();

      final response = await http
          .post(
            Uri.parse('$_kApiBaseUrl/auth/verify-otp'),
            headers: const {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(_kApiTimeout);

      if (!mounted) return;

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) {
          successPayload = decoded;
        } else {
          _error = 'Unexpected response format from server.';
        }
      } else {
        _error = _extractError(response) ??
            'Verification failed (HTTP ${response.statusCode}).';
      }
    } on TimeoutException {
      _error = 'Connection timed out. Please try again.';
    } catch (e) {
      _error = 'Network error: $e';
    } finally {
      if (mounted) {
        setState(() => _isVerifying = false);
      }
    }

    // Pop AFTER the finally block so the sheet's own state is consistent
    // before it disappears. `successPayload` will be non-null only on the
    // happy path.
    if (successPayload != null && mounted) {
      Navigator.of(context).pop(successPayload);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Drag handle.
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),

              Text(
                'Enter OTP sent to your Email',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                "We sent a 4-digit code to\nDidn't receive it? Check your Spam folder.",
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                widget.email,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: _kBrandGreen,
                ),
              ),
              const SizedBox(height: 24),

              TextFormField(
                controller: _otpController,
                enabled: !_isVerifying,
                autofocus: true,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(4),
                ],
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 28,
                  letterSpacing: 12,
                  fontWeight: FontWeight.bold,
                ),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  counterText: '',
                  hintText: '••••',
                  hintStyle: TextStyle(letterSpacing: 12),
                ),
                validator: (v) {
                  final value = (v ?? '').trim();
                  if (value.isEmpty) return 'Enter the OTP';
                  if (value.length != 4) return 'OTP must be 4 digits';
                  return null;
                },
                onFieldSubmitted: (_) {
                  if (!_isVerifying) _verify();
                },
              ),

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

              const SizedBox(height: 24),

              FilledButton.icon(
                onPressed: _isVerifying ? null : _verify,
                style: FilledButton.styleFrom(
                  backgroundColor: _kBrandGreen,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  textStyle: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                ),
                icon: _isVerifying
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.verified_outlined),
                label: Text(
                  _isVerifying ? 'Verifying…' : 'CONFIRM & REGISTER',
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _isVerifying
                    ? null
                    : () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}