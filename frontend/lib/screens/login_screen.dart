import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../services/api_service.dart';
import 'farmer_dashboard.dart';
import 'rider_dashboard.dart';
import 'signup_screen.dart';

/// Brand green, matching the signup screen and the rest of the app.
const Color _kBrandGreen = Color(0xFF2E7D32);

/// Email + password login screen.
///
/// On success, routes to [FarmerDashboard] or [RiderDashboard] based on
/// the `role` field on the user object returned by `POST /auth/login`.
/// On failure, surfaces the backend's `detail` message (e.g. "Invalid
/// email or password") in a red SnackBar.
///
/// Also exposes the "Forgot Password?" flow, which opens a two-step
/// modal bottom sheet:
///   1. Enter email → POST /auth/forgot-password
///   2. Enter OTP + new password → POST /auth/reset-password
/// On success the sheet closes, the login email field is pre-filled, and
/// a green SnackBar confirms the reset.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  bool _obscurePassword = true;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Actions
  // -------------------------------------------------------------------------

  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;

    final auth = context.read<AuthProvider>();
    final email = _emailController.text.trim().toLowerCase();
    final password = _passwordController.text;

    final success = await auth.login(email, password);
    if (!mounted) return;

    if (!success) {
      final message = auth.lastError ?? 'Login failed. Please try again.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.red.shade700,
        ),
      );
      return;
    }

    // `auth.role` is populated by the provider's `login()` from the user
    // object the backend returned. Route on it, not on any client-side
    // guess — the server is the authority on which role this session has.
    final role = auth.role ?? 'FARMER';

    // Success feedback, then replace the nav stack so "back" doesn't
    // return to the login form.
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Logged in successfully!'),
        backgroundColor: _kBrandGreen,
      ),
    );

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => role == 'RIDER'
            ? const RiderDashboard()
            : const FarmerDashboard(),
      ),
      (route) => false,
    );
  }

  void _handleCreateAccount() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SignupScreen()),
    );
  }

  /// Opens the Forgot Password modal bottom sheet. If the user completes
  /// the reset, the sheet returns the verified email address, which we
  /// then use to pre-fill the login form and show a success SnackBar.
  Future<void> _handleForgotPassword() async {
    final resetEmail = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _ForgotPasswordSheet(),
    );

    if (!mounted || resetEmail == null) return;

    // Pre-fill the login form with the email that was just reset.
    _emailController.text = resetEmail;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Password reset successfully! Please log in with your new password.',
        ),
        backgroundColor: _kBrandGreen,
        duration: Duration(seconds: 4),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: Colors.grey.shade50,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Card(
                elevation: 1,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildHeader(theme),
                        const SizedBox(height: 32),
                        _buildEmailField(),
                        const SizedBox(height: 16),
                        _buildPasswordField(),
                        _buildForgotPasswordButton(auth),
                        const SizedBox(height: 16),
                        _buildLoginButton(auth),
                        const SizedBox(height: 12),
                        _buildCreateAccountButton(auth),
                        const SizedBox(height: 12),
                        Center(
                          child: Text(
                            'Trouble signing in? Contact support.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: _kBrandGreen.withOpacity(0.08),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.agriculture_rounded,
            size: 52,
            color: _kBrandGreen,
          ),
        ),
        const SizedBox(height: 20),
        Text(
          'KisanRider',
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.bold,
            color: _kBrandGreen,
            letterSpacing: 0.4,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Agricultural logistics, connected.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildEmailField() {
    return TextFormField(
      controller: _emailController,
      enabled: !context.watch<AuthProvider>().isLoggingIn,
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
        // Pragmatic check — matches what the backend's EmailStr accepts in
        // the common case. The server runs its own validation too; this is
        // just for fast client-side feedback.
        final emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
        if (!emailRe.hasMatch(value)) return 'Enter a valid email address';
        return null;
      },
    );
  }

  Widget _buildPasswordField() {
    return TextFormField(
      controller: _passwordController,
      enabled: !context.watch<AuthProvider>().isLoggingIn,
      obscureText: _obscurePassword,
      decoration: InputDecoration(
        labelText: 'Password',
        hintText: 'Enter your password',
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
        if ((v ?? '').isEmpty) return 'Password is required';
        return null;
      },
      onFieldSubmitted: (_) {
        if (!context.read<AuthProvider>().isLoggingIn) _handleLogin();
      },
    );
  }

  /// Text button aligned to the right, directly under the password field.
  Widget _buildForgotPasswordButton(AuthProvider auth) {
    return Align(
      alignment: Alignment.centerRight,
      child: TextButton(
        onPressed: auth.isLoggingIn ? null : _handleForgotPassword,
        style: TextButton.styleFrom(
          foregroundColor: _kBrandGreen,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          minimumSize: const Size(0, 32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: const Text(
          'Forgot Password?',
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildLoginButton(AuthProvider auth) {
    return FilledButton.icon(
      onPressed: auth.isLoggingIn ? null : _handleLogin,
      style: FilledButton.styleFrom(
        backgroundColor: _kBrandGreen,
        padding: const EdgeInsets.symmetric(vertical: 16),
        textStyle: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
      icon: auth.isLoggingIn
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : const Icon(Icons.login_rounded),
      label: Text(auth.isLoggingIn ? 'Logging in…' : 'Log In'),
    );
  }

  Widget _buildCreateAccountButton(AuthProvider auth) {
    return OutlinedButton.icon(
      onPressed: auth.isLoggingIn ? null : _handleCreateAccount,
      style: OutlinedButton.styleFrom(
        foregroundColor: _kBrandGreen,
        side: const BorderSide(color: _kBrandGreen),
        padding: const EdgeInsets.symmetric(vertical: 16),
        textStyle: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
      icon: const Icon(Icons.person_add_alt_1_outlined),
      label: const Text('Create a new account'),
    );
  }
}

// ============================================================================
// Forgot Password modal bottom sheet (2-step flow)
// ============================================================================

/// Two-step modal that handles the email-OTP password reset.
///
/// Step 1 — request the OTP by email:
///   POST /auth/forgot-password   body: {email}
/// Step 2 — verify the OTP and set a new password:
///   POST /auth/reset-password    body: {email, otp, new_password}
///
/// On success, the sheet pops itself and returns the verified email
/// address to the caller, which uses it to pre-fill the login form.
class _ForgotPasswordSheet extends StatefulWidget {
  const _ForgotPasswordSheet();

  @override
  State<_ForgotPasswordSheet> createState() => _ForgotPasswordSheetState();
}

class _ForgotPasswordSheetState extends State<_ForgotPasswordSheet> {
  static const int _stepRequest = 0;
  static const int _stepReset = 1;

  final GlobalKey<FormState> _requestFormKey = GlobalKey<FormState>();
  final GlobalKey<FormState> _resetFormKey = GlobalKey<FormState>();

  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _otpController = TextEditingController();
  final TextEditingController _newPasswordController = TextEditingController();
  final TextEditingController _confirmPasswordController =
      TextEditingController();

  int _step = _stepRequest;
  String _submittedEmail = '';

  bool _isSubmitting = false;
  bool _obscureNewPassword = true;
  bool _obscureConfirmPassword = true;

  @override
  void dispose() {
    _emailController.dispose();
    _otpController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // API calls
  // -------------------------------------------------------------------------

  Future<void> _sendResetOtp() async {
    if (!_requestFormKey.currentState!.validate()) return;

    final email = _emailController.text.trim().toLowerCase();
    setState(() => _isSubmitting = true);

    try {
      await ApiService.dio.post(
        '/auth/forgot-password',
        data: {'email': email},
      );

      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _submittedEmail = email;
        _step = _stepReset;
      });
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      _showError(_messageFromDioException(e, 'Could not send reset OTP.'));
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      _showError('Unexpected error: $e');
    }
  }

  Future<void> _resetPassword() async {
    if (!_resetFormKey.currentState!.validate()) return;

    final otp = _otpController.text.trim();
    final newPassword = _newPasswordController.text;
    setState(() => _isSubmitting = true);

    try {
      await ApiService.dio.post(
        '/auth/reset-password',
        data: {
          'email': _submittedEmail,
          'otp': otp,
          'new_password': newPassword,
        },
      );

      if (!mounted) return;
      // Return the verified email to the caller so the login screen can
      // pre-fill the email field and show the success SnackBar.
      Navigator.of(context).pop(_submittedEmail);
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      _showError(_messageFromDioException(e, 'Password reset failed.'));
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      _showError('Unexpected error: $e');
    }
  }

  String _messageFromDioException(DioException e, String fallback) {
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.sendTimeout) {
      return 'Connection to server timed out. Is the backend running?';
    }
    if (e.type == DioExceptionType.connectionError) {
      return 'Could not connect to server at ${ApiService.baseUrl}.';
    }
    final status = e.response?.statusCode;
    if (status != null) {
      final data = e.response?.data;
      final detail = data is Map ? data['detail']?.toString() : null;
      return detail ?? '$fallback (status $status)';
    }
    return e.message ?? fallback;
  }

  void _showError(String message) {
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.red.shade700,
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  void _goBackToRequestStep() {
    setState(() {
      _step = _stepRequest;
      _otpController.clear();
      _newPasswordController.clear();
      _confirmPasswordController.clear();
    });
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final theme = Theme.of(context);

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
                _buildDragHandle(),
                const SizedBox(height: 12),
                _buildHeader(theme),
                const SizedBox(height: 20),
                // AnimatedSize keeps the sheet height transition smooth when
                // the two steps have different heights; AnimatedSwitcher
                // cross-fades the step content itself.
                AnimatedSize(
                  duration: const Duration(milliseconds: 280),
                  curve: Curves.easeOutCubic,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 280),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) {
                      return FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position: Tween<Offset>(
                            begin: const Offset(0.06, 0),
                            end: Offset.zero,
                          ).animate(animation),
                          child: child,
                        ),
                      );
                    },
                    child: _step == _stepRequest
                        ? _buildRequestStep(theme)
                        : _buildResetStep(theme),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDragHandle() {
    return Center(
      child: Container(
        width: 44,
        height: 4,
        decoration: BoxDecoration(
          color: Colors.grey.shade300,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    final isRequest = _step == _stepRequest;
    final title = isRequest ? 'Forgot Password?' : 'Reset Password';
    final subtitle = isRequest
        ? 'Enter your account email — we will send you a 4-digit reset code.'
        : 'Enter the code we sent and choose a new password.';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: _kBrandGreen.withOpacity(0.08),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.lock_reset_rounded,
                color: _kBrandGreen,
                size: 24,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: _kBrandGreen,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          subtitle,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // Step 1 — Request OTP
  // -------------------------------------------------------------------------

  Widget _buildRequestStep(ThemeData theme) {
    return KeyedSubtree(
      key: const ValueKey('forgot_step_request'),
      child: Form(
        key: _requestFormKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: _emailController,
              enabled: !_isSubmitting,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.done,
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
                final emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
                if (!emailRe.hasMatch(value)) {
                  return 'Enter a valid email address';
                }
                return null;
              },
              onFieldSubmitted: (_) {
                if (!_isSubmitting) _sendResetOtp();
              },
            ),
            const SizedBox(height: 20),
            _buildSubmitButton(
              label: 'SEND RESET OTP',
              onPressed: _sendResetOtp,
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Step 2 — Verify OTP + set new password
  // -------------------------------------------------------------------------

  Widget _buildResetStep(ThemeData theme) {
    return KeyedSubtree(
      key: const ValueKey('forgot_step_reset'),
      child: Form(
        key: _resetFormKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Recipient email chip
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 12,
              ),
              decoration: BoxDecoration(
                color: _kBrandGreen.withOpacity(0.06),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _kBrandGreen.withOpacity(0.20)),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.mark_email_read_outlined,
                    color: _kBrandGreen,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Code sent to',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _submittedEmail,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // OTP field — 4 digits, numeric only.
            TextFormField(
              controller: _otpController,
              enabled: !_isSubmitting,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.next,
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
                if (value.isEmpty) return 'OTP is required';
                if (!RegExp(r'^\d{4}$').hasMatch(value)) {
                  return 'Enter the 4-digit code from your email';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),

            // New password
            TextFormField(
              controller: _newPasswordController,
              enabled: !_isSubmitting,
              obscureText: _obscureNewPassword,
              decoration: InputDecoration(
                labelText: 'New Password',
                hintText: 'At least 6 characters',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  tooltip:
                      _obscureNewPassword ? 'Show password' : 'Hide password',
                  icon: Icon(
                    _obscureNewPassword
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  onPressed: () => setState(
                    () => _obscureNewPassword = !_obscureNewPassword,
                  ),
                ),
              ),
              validator: (v) {
                final value = v ?? '';
                if (value.isEmpty) return 'New password is required';
                if (value.length < 6) {
                  return 'Password must be at least 6 characters';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),

            // Confirm password
            TextFormField(
              controller: _confirmPasswordController,
              enabled: !_isSubmitting,
              obscureText: _obscureConfirmPassword,
              decoration: InputDecoration(
                labelText: 'Confirm New Password',
                hintText: 'Re-enter your new password',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.lock_reset_outlined),
                suffixIcon: IconButton(
                  tooltip: _obscureConfirmPassword
                      ? 'Show password'
                      : 'Hide password',
                  icon: Icon(
                    _obscureConfirmPassword
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  onPressed: () => setState(
                    () => _obscureConfirmPassword = !_obscureConfirmPassword,
                  ),
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
              onFieldSubmitted: (_) {
                if (!_isSubmitting) _resetPassword();
              },
            ),
            const SizedBox(height: 20),

            _buildSubmitButton(
              label: 'RESET PASSWORD',
              onPressed: _resetPassword,
            ),
            const SizedBox(height: 4),

            // Escape hatch back to email entry.
            Center(
              child: TextButton(
                onPressed: _isSubmitting ? null : _goBackToRequestStep,
                style: TextButton.styleFrom(
                  foregroundColor: _kBrandGreen,
                  textStyle: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                child: const Text('Use a different email'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSubmitButton({
    required String label,
    required VoidCallback onPressed,
  }) {
    return FilledButton(
      onPressed: _isSubmitting ? null : onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: _kBrandGreen,
        padding: const EdgeInsets.symmetric(vertical: 16),
        textStyle: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
        ),
      ),
      child: _isSubmitting
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