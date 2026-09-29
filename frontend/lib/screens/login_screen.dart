import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
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
                        const SizedBox(height: 28),
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