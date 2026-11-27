import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/language_provider.dart';

/// Exact-English-keyed localization dictionary for English (`en`) and Kannada (`kn`).
///
/// When `currentLanguage == 'en'`, [tr] returns the exact English string unchanged
/// (applying any `{key}` parameter substitutions), guaranteeing English screens
/// stay identical byte-for-byte.
class AppStrings {
  AppStrings._();

  static String currentLanguage = 'en';

  static String tr(
    String text, {
    Map<String, String>? args,
    String? lang,
  }) {
    final code = lang ?? currentLanguage;
    String resolved = text;
    if (code == 'kn') {
      resolved = _kn[text] ?? text;
    }
    if (args != null && args.isNotEmpty) {
      args.forEach((key, value) {
        resolved = resolved.replaceAll('{$key}', value);
      });
    }
    return resolved;
  }

  /// Translates API status tokens for UI badges/labels only; preserves original
  /// text verbatim when English is active.
  static String trStatus(String rawStatus, {String? lang}) {
    final code = lang ?? currentLanguage;
    if (code != 'kn') return rawStatus;
    switch (rawStatus.trim().toUpperCase()) {
      case 'PENDING':
        return 'ಬಾಕಿ ಇದೆ';
      case 'ACCEPTED':
        return 'ಒಪ್ಪಿಕೊಳ್ಳಲಾಗಿದೆ';
      case 'PICKED_UP':
      case 'PICKED UP':
        return 'ಪಿಕಪ್ ಆಗಿದೆ';
      case 'IN_TRANSIT':
      case 'IN TRANSIT':
        return 'ಸಾಗಣೆಯಲ್ಲಿದೆ';
      case 'DELIVERED':
        return 'ತಲುಪಿಸಲಾಗಿದೆ';
      case 'COMPLETED':
        return 'ಪೂರ್ಣಗೊಂಡಿದೆ';
      case 'CANCELLED':
        return 'ರದ್ದುಗೊಂಡಿದೆ';
      case 'EXPIRED':
        return 'ಅವಧಿ ಮುಗಿದಿದೆ';
      case 'MISSED':
        return 'ತಪ್ಪಿಹೋಗಿದೆ';
      case 'PAID':
        return 'ಪಾವತಿಸಲಾಗಿದೆ';
      case 'OPEN':
        return 'ತೆರೆದಿದೆ';
      case 'LOCKED':
        return 'ಲಾಕ್ ಆಗಿದೆ';
      case 'READY':
        return 'ಸಿದ್ಧವಾಗಿದೆ';
      case 'ACTIVE':
        return 'ಸಕ್ರಿಯ';
      case 'OFFLINE':
        return 'ಆಫ್‌ಲೈನ್';
      case 'ON-DUTY':
      case 'ON DUTY':
        return 'ಡ್ಯೂಟಿಯಲ್ಲಿದೆ';
      case 'PENDING QR':
        return 'QR ಬಾಕಿ ಇದೆ';
      case 'PAID ✅':
        return 'ಪಾವತಿಸಲಾಗಿದೆ ✅';
      case 'QR PAY':
        return 'QR ಪಾವತಿ';
      case 'ACTIVE POOL':
        return 'ಸಕ್ರಿಯ ಪೂಲ್';
      case 'SETTLED':
        return 'ಪಾವತಿ ಇತ್ಯರ್ಥವಾಗಿದೆ';
      case 'FULL':
        return 'ಭರ್ತಿಯಾಗಿದೆ';
      case 'DRIVER_ASSIGNED':
      case 'DRIVER ASSIGNED':
        return 'ಚಾಲಕ ನಿಯೋಜಿಸಲಾಗಿದೆ';
      case 'REQUESTED':
        return 'ವಿನಂತಿಸಲಾಗಿದೆ';
      case 'APPROVED':
        return 'ಅನುಮೋದಿಸಲಾಗಿದೆ';
      case 'REJECTED':
        return 'ತಿರಸ್ಕರಿಸಲಾಗಿದೆ';
      case 'FAILED':
        return 'ವಿಫಲವಾಗಿದೆ';
      case 'UNPAID':
        return 'ಪಾವತಿಸಿಲ್ಲ';
      case 'IN_PROGRESS':
      case 'IN PROGRESS':
        return 'ಪ್ರಗತಿಯಲ್ಲಿದೆ';
      default:
        return rawStatus;
    }
  }

  /// Translates a role token for display (`FARMER` / `RIDER` / `ADMIN`).
  static String trRole(String rawRole, {String? lang}) {
    final code = lang ?? currentLanguage;
    if (code != 'kn') return rawRole;
    switch (rawRole.trim().toUpperCase()) {
      case 'FARMER':
        return 'ರೈತರು';
      case 'RIDER':
        return 'ರೈಡರ್';
      case 'ADMIN':
        return 'ನಿರ್ವಾಹಕರು';
      default:
        return rawRole;
    }
  }

  /// Short month label (`month1Based` = 1..12).
  static String trShortMonth(int month1Based, {String? lang}) {
    const en = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    const kn = [
      'ಜನ', 'ಫೆಬ್ರ', 'ಮಾರ್ಚ್', 'ಏಪ್ರಿ', 'ಮೇ', 'ಜೂನ್',
      'ಜುಲೈ', 'ಆಗ', 'ಸೆಪ್ಟೆಂ', 'ಅಕ್ಟೋ', 'ನವೆಂ', 'ಡಿಸೆಂ',
    ];
    final idx = (month1Based - 1).clamp(0, 11);
    return (lang ?? currentLanguage) == 'kn' ? kn[idx] : en[idx];
  }

  static String trFullMonth(int month1Based, {String? lang}) {
    const en = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    const kn = [
      'ಜನವರಿ', 'ಫೆಬ್ರವರಿ', 'ಮಾರ್ಚ್', 'ಏಪ್ರಿಲ್', 'ಮೇ', 'ಜೂನ್',
      'ಜುಲೈ', 'ಆಗಸ್ಟ್', 'ಸೆಪ್ಟೆಂಬರ್', 'ಅಕ್ಟೋಬರ್', 'ನವೆಂಬರ್', 'ಡಿಸೆಂಬರ್',
    ];
    final idx = (month1Based - 1).clamp(0, 11);
    return (lang ?? currentLanguage) == 'kn' ? kn[idx] : en[idx];
  }

  static const Map<String, String> _kn = {
    // App & Auth
    'KisanRider': 'ಕಿಸಾನ್‌ರೈಡರ್',
    'KisanRider Mandi Pay': 'ಕಿಸಾನ್‌ರೈಡರ್ ಮಂಡಿ ಪೇ',
    'Agricultural logistics, connected.': 'ಕೃಷಿ ಸಾಗಣೆ, ಸಂಪರ್ಕಿತ ಸೇವೆ.',
    'Agricultural logistics, connected across Karnataka':
        'ಕರ್ನಾಟಕದಾದ್ಯಂತ ಕೃಷಿ ಸಾಗಣೆ ಸಂಪರ್ಕ',
    'Email Address': 'ಇಮೇಲ್ ವಿಳಾಸ',
    'Email is required': 'ಇಮೇಲ್ ಅಗತ್ಯವಿದೆ',
    'Enter a valid email address': 'ಸರಿಯಾದ ಇಮೇಲ್ ವಿಳಾಸವನ್ನು ನಮೂದಿಸಿ',
    'Password': 'ಪಾಸ್‌ವರ್ಡ್',
    'Enter your password': 'ನಿಮ್ಮ ಪಾಸ್‌ವರ್ಡ್ ನಮೂದಿಸಿ',
    'Show password': 'ಪಾಸ್‌ವರ್ಡ್ ತೋರಿಸಿ',
    'Hide password': 'ಪಾಸ್‌ವರ್ಡ್ ಮರೆಮಾಡಿ',
    'Show': 'ತೋರಿಸಿ',
    'Hide': 'ಮರೆಮಾಡಿ',
    'Password is required': 'ಪಾಸ್‌ವರ್ಡ್ ಅಗತ್ಯವಿದೆ',
    'Password must be at least 6 characters':
        'ಪಾಸ್‌ವರ್ಡ್ ಕನಿಷ್ಠ 6 ಅಕ್ಷರಗಳಾಗಿರಬೇಕು',
    'At least 6 characters': 'ಕನಿಷ್ಠ 6 ಅಕ್ಷರಗಳು',
    'Forgot Password?': 'ಪಾಸ್‌ವರ್ಡ್ ಮರೆತಿರಾ?',
    'Logging in…': 'ಲಾಗಿನ್ ಆಗುತ್ತಿದೆ…',
    'Log In': 'ಲಾಗಿನ್',
    'Login': 'ಲಾಗಿನ್',
    'Create a new account': 'ಹೊಸ ಖಾತೆ ರಚಿಸಿ',
    'Logged in successfully!': 'ಯಶಸ್ವಿಯಾಗಿ ಲಾಗಿನ್ ಆಗಿದ್ದೀರಿ!',
    'Login failed. Please try again.':
        'ಲಾಗಿನ್ ವಿಫಲವಾಗಿದೆ. ದಯವಿಟ್ಟು ಮತ್ತೆ ಪ್ರಯತ್ನಿಸಿ.',
    'Login failed (status {status}).': 'ಲಾಗಿನ್ ವಿಫಲವಾಗಿದೆ (ಸ್ಥಿತಿ {status}).',
    'Login failed.': 'ಲಾಗಿನ್ ವಿಫಲವಾಗಿದೆ.',
    'Unexpected response (status {status}).':
        'ಅನಿರೀಕ್ಷಿತ ಪ್ರತಿಕ್ರಿಯೆ (ಸ್ಥಿತಿ {status}).',
    'No access token returned by server.':
        'ಸರ್ವರ್ ಪ್ರವೇಶ ಟೋಕನ್ ನೀಡಿಲ್ಲ.',
    'Trouble signing in? Contact support.':
        'ಲಾಗಿನ್ ತೊಂದರೆಯೇ? ಬೆಂಬಲವನ್ನು ಸಂಪರ್ಕಿಸಿ.',
    'Reset Password': 'ಪಾಸ್‌ವರ್ಡ್ ಮರುಹೊಂದಿಸಿ',
    'Password reset successfully! Please log in with your new password.':
        'ಪಾಸ್‌ವರ್ಡ್ ಯಶಸ್ವಿಯಾಗಿ ಬದಲಾಗಿದೆ! ದಯವಿಟ್ಟು ಹೊಸ ಪಾಸ್‌ವರ್ಡ್‌ನೊಂದಿಗೆ ಲಾಗಿನ್ ಆಗಿ.',
    'Enter your account email — we will send you a 4-digit reset code.':
        'ನಿಮ್ಮ ಖಾತೆಯ ಇಮೇಲ್ ನಮೂದಿಸಿ — ನಾವು 4-ಅಂಕಿಯ ಕೋಡ್ ಕಳುಹಿಸುತ್ತೇವೆ.',
    'Enter the code we sent and choose a new password.':
        'ನಾವು ಕಳುಹಿಸಿದ ಕೋಡ್ ನಮೂದಿಸಿ ಮತ್ತು ಹೊಸ ಪಾಸ್‌ವರ್ಡ್ ಆಯ್ಕೆಮಾಡಿ.',
    'SEND RESET OTP': 'ರೀಸೆಟ್ OTP ಕಳುಹಿಸಿ',
    'SEND OTP': 'OTP ಕಳುಹಿಸಿ',
    'RESET PASSWORD': 'ಪಾಸ್‌ವರ್ಡ್ ಮರುಹೊಂದಿಸಿ',
    'Code sent to': 'ಕೋಡ್ ಕಳುಹಿಸಲಾಗಿದೆ:',
    'Code sent to {email}': '{email} ಗೆ ಕೋಡ್ ಕಳುಹಿಸಲಾಗಿದೆ',
    '4-Digit OTP': '4-ಅಂಕಿಯ OTP',
    'OTP is required': 'OTP ಅಗತ್ಯವಿದೆ',
    'Enter the 4-digit code from your email':
        'ನಿಮ್ಮ ಇಮೇಲ್‌ನಿಂದ 4-ಅಂಕಿಯ ಕೋಡ್ ನಮೂದಿಸಿ',
    'Enter the 4-digit code': '4-ಅಂಕಿಯ ಕೋಡ್ ನಮೂದಿಸಿ',
    'New Password': 'ಹೊಸ ಪಾಸ್‌ವರ್ಡ್',
    'New password is required': 'ಹೊಸ ಪಾಸ್‌ವರ್ಡ್ ಅಗತ್ಯವಿದೆ',
    'Confirm New Password': 'ಹೊಸ ಪಾಸ್‌ವರ್ಡ್ ದೃಢೀಕರಿಸಿ',
    'Re-enter your new password': 'ನಿಮ್ಮ ಹೊಸ ಪಾಸ್‌ವರ್ಡ್ ಮತ್ತೆ ನಮೂದಿಸಿ',
    'Please confirm your new password': 'ದಯವಿಟ್ಟು ಹೊಸ ಪಾಸ್‌ವರ್ಡ್ ದೃಢೀಕರಿಸಿ',
    'Passwords do not match': 'ಪಾಸ್‌ವರ್ಡ್‌ಗಳು ಹೊಂದಿಕೆಯಾಗುತ್ತಿಲ್ಲ',
    'Use a different email': 'ಬೇರೆ ಇಮೇಲ್ ಬಳಸಿ',
    'Could not send reset OTP.': 'ರೀಸೆಟ್ OTP ಕಳುಹಿಸಲು ಸಾಧ್ಯವಾಗಲಿಲ್ಲ.',
    'Password reset failed.': 'ಪಾಸ್‌ವರ್ಡ್ ಬದಲಾವಣೆ ವಿಫಲವಾಗಿದೆ.',
    'Sign Up': 'ಸೈನ್ ಅಪ್',
    'Create KisanRider Account': 'ಕಿಸಾನ್‌ರೈಡರ್ ಖಾತೆ ರಚಿಸಿ',
    'Full Name': 'ಪೂರ್ಣ ಹೆಸರು',
    'e.g. Ravi Kumar': 'ಉದಾ. ರವಿ ಕುಮಾರ್',
    'Full name is required': 'ಪೂರ್ಣ ಹೆಸರು ಅಗತ್ಯವಿದೆ',
    'Name is required': 'ಹೆಸರು ಅಗತ್ಯವಿದೆ',
    'acres': 'ಎಕರೆ',
    'e.g. 3.5': 'ಉದಾ. 3.5',
    'e.g. name@okicici': 'ಉದಾ. name@okicici',
    'e.g. SBIN0001234': 'ಉದಾ. SBIN0001234',
    'e.g. KA0120190001234': 'ಉದಾ. KA0120190001234',
    'e.g. Tata Ace / Bolero Pickup': 'ಉದಾ. ಟಾಟಾ ಏಸ್ / ಬೊಲೆರೊ ಪಿಕಪ್',
    'e.g. KA01AB1234': 'ಉದಾ. KA01AB1234',
    'e.g. 750': 'ಉದಾ. 750',
    'e.g. Kolar, Bengaluru Urban, Tumakuru':
        'ಉದಾ. ಕೋಲಾರ, ಬೆಂಗಳೂರು ನಗರ, ತುಮಕೂರು',
    'Need a hand?\n\nEmail: support@kisanrider.app\nPhone: +91 1800 000 000\nHours: Mon–Sat, 9 AM to 6 PM IST\n\nFor urgent issues with an active trip, please call the rider directly from the My Orders tab.':
        'ಸಹಾಯ ಬೇಕೇ?\n\nಇಮೇಲ್: support@kisanrider.app\nಫೋನ್: +91 1800 000 000\nಸಮಯ: ಸೋಮ–ಶನಿ, ಬೆಳಗ್ಗೆ 9 ರಿಂದ ಸಂಜೆ 6 IST\n\nಸಕ್ರಿಯ ಟ್ರಿಪ್‌ನ ತುರ್ತು ಸಮಸ್ಯೆಗಳಿಗೆ, ದಯವಿಟ್ಟು ಆರ್ಡರ್‌ಗಳು ಟ್ಯಾಬ್‌ನಿಂದ ರೈಡರ್‌ಗೆ ನೇರವಾಗಿ ಕರೆ ಮಾಡಿ.',
    'KisanRider connects farmers and riders for agricultural transport across Karnataka.\n\nWe collect only what is necessary to operate the service: your name, contact details, farm location, and payout information. Location data is used to match produce requests with nearby riders and is never shared with third parties.\n\nBy continuing to use KisanRider you agree to these terms and to our privacy practices.':
        'ಕಿಸಾನ್‌ರೈಡರ್ ಕರ್ನಾಟಕದಾದ್ಯಂತ ಕೃಷಿ ಸಾಗಣೆಗಾಗಿ ರೈತರು ಮತ್ತು ರೈಡರ್‌ಗಳನ್ನು ಸಂಪರ್ಕಿಸುತ್ತದೆ.\n\nಸೇವೆಯನ್ನು ನಿರ್ವಹಿಸಲು ಅಗತ್ಯವಿರುವ ಮಾಹಿತಿಯನ್ನು ಮಾತ್ರ ನಾವು ಸಂಗ್ರಹಿಸುತ್ತೇವೆ: ನಿಮ್ಮ ಹೆಸರು, ಸಂಪರ್ಕ ವಿವರಗಳು, ಜಮೀನಿನ ಸ್ಥಳ ಮತ್ತು ಪಾವತಿ ಮಾಹಿತಿ. ಸ್ಥಳ ಮಾಹಿತಿಯನ್ನು ಹತ್ತಿರದ ರೈಡರ್‌ಗಳೊಂದಿಗೆ ಹೊಂದಿಸಲು ಮಾತ್ರ ಬಳಸಲಾಗುತ್ತದೆ ಮತ್ತು ಮೂರನೇ ವ್ಯಕ್ತಿಗಳೊಂದಿಗೆ ಹಂಚಿಕೊಳ್ಳುವುದಿಲ್ಲ.\n\nಕಿಸಾನ್‌ರೈಡರ್ ಬಳಕೆಯನ್ನು ಮುಂದುವರಿಸುವ ಮೂಲಕ ನೀವು ಈ ನಿಯಮಗಳಿಗೆ ಮತ್ತು ಗೌಪ್ಯತಾ ನೀತಿಗೆ ಒಪ್ಪುತ್ತೀರಿ.',
    'Need help on the road?\n\nRider Helpline: +91 1800 000 111\nEmail: riders@kisanrider.app\nHours: Mon–Sat, 9 AM to 9 PM IST\n\nFor safety emergencies, dial 112 directly.\n\nCommon questions:\n• How is my payout calculated? — Tap a completed trip under Earnings.\n• What if the farmer\'s OTP does not work? — Ask them to open My Orders and read the 4-digit code.\n• Trip cancelled mid-route? — Contact the helpline immediately with the trip ID.':
        'ರಸ್ತೆಯಲ್ಲಿ ಸಹಾಯ ಬೇಕೇ?\n\nರೈಡರ್ ಸಹಾಯವಾಣಿ: +91 1800 000 111\nಇಮೇಲ್: riders@kisanrider.app\nಸಮಯ: ಸೋಮ–ಶನಿ, ಬೆಳಗ್ಗೆ 9 ರಿಂದ ರಾತ್ರಿ 9 IST\n\nಸುರಕ್ಷತಾ ತುರ್ತು ಪರಿಸ್ಥಿತಿಗಾಗಿ, ನೇರವಾಗಿ 112 ಕ್ಕೆ ಕರೆ ಮಾಡಿ.\n\nಸಾಮಾನ್ಯ ಪ್ರಶ್ನೆಗಳು:\n• ನನ್ನ ಪಾವತಿ ಹೇಗೆ ಲೆಕ್ಕಹಾಕಲಾಗುತ್ತದೆ? — ಗಳಿಕೆ ಟ್ಯಾಬ್‌ನಲ್ಲಿ ಪೂರ್ಣಗೊಂಡ ಟ್ರಿಪ್ ಒತ್ತಿರಿ.\n• ರೈತರ OTP ಕೆಲಸ ಮಾಡದಿದ್ದರೆ? — ಆರ್ಡರ್‌ಗಳು ತೆರೆದು 4-ಅಂಕಿಯ ಕೋಡ್ ಓದಲು ಕೇಳಿ.\n• ಮಾರ್ಗಮಧ್ಯೆ ಟ್ರಿಪ್ ರದ್ದಾದರೆ? — ಟ್ರಿಪ್ ID ಯೊಂದಿಗೆ ತಕ್ಷಣ ಸಹಾಯವಾಣಿಗೆ ಕರೆ ಮಾಡಿ.',
    'Guidelines for safe freight hauling on KisanRider:\n\n1. Verify the pickup OTP before loading any crates. Never load without it.\n2. Photograph the loaded crates and the delivered consignment as proof.\n3. Payload limits: do not exceed your vehicle\'s declared capacity.\n4. Crate handling: stack no more than three high, and keep produce out of direct sun.\n5. Report accidents or spills within 15 minutes.\n6. Earnings settle within 24 hours of a successful delivery.\n\nBy continuing to accept trips you agree to these rules and to KisanRider\'s privacy practices.':
        'ಕಿಸಾನ್‌ರೈಡರ್‌ನಲ್ಲಿ ಸುರಕ್ಷಿತ ಸಾಗಣೆ ಮಾರ್ಗಸೂಚಿಗಳು:\n\n1. ಯಾವುದೇ ಕ್ರೇಟ್‌ಗಳನ್ನು ಲೋಡ್ ಮಾಡುವ ಮೊದಲು ಪಿಕಪ್ OTP ಪರಿಶೀಲಿಸಿ.\n2. ಲೋಡ್ ಮಾಡಿದ ಕ್ರೇಟ್‌ಗಳು ಮತ್ತು ತಲುಪಿಸಿದ ಸರಕಿನ ಫೋಟೋ ತೆಗೆಯಿರಿ.\n3. ಭಾರದ ಮಿತಿ: ನಿಮ್ಮ ವಾಹನದ ಘೋಷಿತ ಸಾಮರ್ಥ್ಯವನ್ನು ಮೀರಬೇಡಿ.\n4. ಕ್ರೇಟ್ ನಿರ್ವಹಣೆ: ಮೂರಕ್ಕಿಂತ ಹೆಚ್ಚು ಎತ್ತರದಲ್ಲಿ ಜೋಡಿಸಬೇಡಿ ಮತ್ತು ಬಿಸಿಲಿನಿಂದ ರಕ್ಷಿಸಿ.\n5. ಅಪಘಾತಗಳು ಅಥವಾ ಹಾನಿಯನ್ನು 15 ನಿಮಿಷಗಳಲ್ಲಿ ವರದಿ ಮಾಡಿ.\n6. ಯಶಸ್ವಿ ವಿತರಣೆಯ 24 ಗಂಟೆಗಳಲ್ಲಿ ಗಳಿಕೆ ಇತ್ಯರ್ಥವಾಗುತ್ತದೆ.\n\nಟ್ರಿಪ್‌ಗಳನ್ನು ಸ್ವೀಕರಿಸುವ ಮೂಲಕ ನೀವು ಈ ನಿಯಮಗಳಿಗೆ ಒಪ್ಪುತ್ತೀರಿ.',
    'Name is too short': 'ಹೆಸರು ತುಂಬಾ ಚಿಕ್ಕದಾಗಿದೆ',
    'I am a': 'ನಾನು',
    'Farmer — I want to ship my produce':
        'ರೈತ — ನನ್ನ ಬೆಳೆಯನ್ನು ಸಾಗಿಸಲು ಬಯಸುತ್ತೇನೆ',
    'Rider — I want to transport produce':
        'ರೈಡರ್ — ಬೆಳೆ ಸಾಗಣೆ ಮಾಡಲು ಬಯಸುತ್ತೇನೆ',
    'Please select a role': 'ದಯವಿಟ್ಟು ಒಂದು ಪಾತ್ರವನ್ನು ಆಯ್ಕೆಮಾಡಿ',
    'State': 'ರಾಜ್ಯ',
    'Karnataka': 'ಕರ್ನಾಟಕ',
    'Currently available only in Karnataka':
        'ಪ್ರಸ್ತುತ ಕರ್ನಾಟಕದಲ್ಲಿ ಮಾತ್ರ ಲಭ್ಯವಿದೆ',
    'District': 'ಜಿಲ್ಲೆ',
    'Please select your district': 'ದಯವಿಟ್ಟು ನಿಮ್ಮ ಜಿಲ್ಲೆಯನ್ನು ಆಯ್ಕೆಮಾಡಿ',
    'I agree to the Terms & Conditions and Privacy Policy':
        'ನಿಯಮಗಳು ಮತ್ತು ಗೌಪ್ಯತಾ ನೀತಿಗೆ ನಾನು ಒಪ್ಪುತ್ತೇನೆ',
    'Please accept the Terms & Conditions to continue.':
        'ಮುಂದುವರಿಯಲು ದಯವಿಟ್ಟು ನಿಯಮಗಳನ್ನು ಒಪ್ಪಿಕೊಳ್ಳಿ.',
    'Sending OTP…': 'OTP ಕಳುಹಿಸಲಾಗುತ್ತಿದೆ…',
    'VERIFY EMAIL & REGISTER': 'ಇಮೇಲ್ ಪರಿಶೀಲಿಸಿ ಮತ್ತು ನೋಂದಾಯಿಸಿ',
    'Enter OTP sent to your Email': 'ನಿಮ್ಮ ಇಮೇಲ್‌ಗೆ ಬಂದ OTP ನಮೂದಿಸಿ',
    "We sent a 4-digit code to\nDidn't receive it? Check your Spam folder.":
        'ನಾವು 4-ಅಂಕಿಯ ಕೋಡ್ ಕಳುಹಿಸಿದ್ದೇವೆ\nಬರಲಿಲ್ಲವೇ? ಸ್ಪ್ಯಾಮ್ (Spam) ಫೋಲ್ಡರ್ ಪರಿಶೀಲಿಸಿ.',
    'Enter the OTP': 'OTP ನಮೂದಿಸಿ',
    'OTP must be 4 digits': 'OTP 4 ಅಂಕಿಗಳಾಗಿರಬೇಕು',
    'Verifying…': 'ಪರಿಶೀಲಿಸಲಾಗುತ್ತಿದೆ…',
    'CONFIRM & REGISTER': 'ದೃಢೀಕರಿಸಿ ಮತ್ತು ನೋಂದಾಯಿಸಿ',
    'Account created successfully!': 'ಖಾತೆ ಯಶಸ್ವಿಯಾಗಿ ರಚನೆಯಾಗಿದೆ!',
    'Signup failed (HTTP {code}).': 'ನೋಂದಣಿ ವಿಫಲವಾಗಿದೆ (HTTP {code}).',
    'Verification failed (HTTP {code}).': 'ಪರಿಶೀಲನೆ ವಿಫಲವಾಗಿದೆ (HTTP {code}).',
    'Unexpected response format from server.': 'ಸರ್ವರ್‌ನಿಂದ ಅನಿರೀಕ್ಷಿತ ಪ್ರತಿಕ್ರಿಯೆ.',
    'Server returned an incomplete session.': 'ಸರ್ವರ್ ಅಪೂರ್ಣ ಸೆಷನ್ ನೀಡಿದೆ.',
    'Server returned an incomplete session. Please retry.':
        'ಸರ್ವರ್ ಅಪೂರ್ಣ ಸೆಷನ್ ನೀಡಿದೆ. ಮತ್ತೆ ಪ್ರಯತ್ನಿಸಿ.',
    'Could not save session.': 'ಸೆಷನ್ ಉಳಿಸಲು ಸಾಧ್ಯವಾಗಲಿಲ್ಲ.',
    'Connection to server timed out. Is the backend running?':
        'ಸರ್ವರ್ ಸಂಪರ್ಕ ಸಮಯ ಮೀರಿದೆ.',
    'Could not connect to server at {url}.': '{url} ಸರ್ವರ್‌ಗೆ ಸಂಪರ್ಕಿಸಲು ಸಾಧ್ಯವಾಗಲಿಲ್ಲ.',
    'Connection timed out. Please check your internet and try again.':
        'ಸಂಪರ್ಕ ಸಮಯ ಮೀರಿದೆ. ನಿಮ್ಮ ಇಂಟರ್ನೆಟ್ ಪರಿಶೀಲಿಸಿ ಮತ್ತೆ ಪ್ರಯತ್ನಿಸಿ.',
    'Connection timed out. Please try again.':
        'ಸಂಪರ್ಕ ಸಮಯ ಮೀರಿದೆ. ದಯವಿಟ್ಟು ಮತ್ತೆ ಪ್ರಯತ್ನಿಸಿ.',

    // Navigation & Common
    'Home': 'ಮುಖಪುಟ',
    'My Orders': 'ಆರ್ಡರ್‌ಗಳು',
    'Earnings': 'ಗಳಿಕೆ',
    'Account': 'ಖಾತೆ',
    'Available': 'ಲಭ್ಯ',
    'Available Requests': 'ಲಭ್ಯ ವಿನಂತಿಗಳು',
    'Active': 'ಸಕ್ರಿಯ',
    'Active Trips': 'ಸಕ್ರಿಯ ಟ್ರಿಪ್‌ಗಳು',
    'Logout': 'ಲಾಗ್ ಔಟ್',
    'Log Out': 'ಲಾಗ್ ಔಟ್',
    'LOG OUT': 'ಲಾಗ್ ಔಟ್',
    'Log out?': 'ಲಾಗ್ ಔಟ್ ಮಾಡಬೇಕೆ?',
    'Are you sure you want to log out?': 'ನೀವು ಖಚಿತವಾಗಿ ಲಾಗ್ ಔಟ್ ಮಾಡಲು ಬಯಸುವಿರಾ?',
    'Cancel': 'ರದ್ದುಮಾಡಿ',
    'Close': 'ಮುಚ್ಚಿ',
    'OK': 'ಸರಿ',
    'kg': 'ಕೆಜಿ',
    'Done': 'ಮುಗಿಯಿತು',
    'Retry': 'ಮತ್ತೆ ಪ್ರಯತ್ನಿಸಿ',
    'Refresh': 'ರಿಫ್ರೆಶ್',
    'Clear': 'ತೆರವುಗೊಳಿಸಿ',
    'Save': 'ಉಳಿಸಿ',
    'Saved successfully.': 'ಯಶಸ್ವಿಯಾಗಿ ಉಳಿಸಲಾಗಿದೆ.',
    'Not signed in.': 'ಸೈನ್ ಇನ್ ಆಗಿಲ್ಲ.',
    'Unknown': 'ತಿಳಿದಿಲ್ಲ',
    'Unknown Location': 'ತಿಳಿಯದ ಸ್ಥಳ',
    'Unknown Destination': 'ತಿಳಿಯದ ಗಮ್ಯಸ್ಥಾನ',
    'Farmer': 'ರೈತ',
    'Rider': 'ರೈಡರ್',
    'Driver': 'ಚಾಲಕ',
    'Produce': 'ಬೆಳೆ',
    'Crop': 'ಬೆಳೆ',
    'Weight': 'ತೂಕ',
    'Distance': 'ದೂರ',
    'Pickup': 'ಪಿಕಪ್',
    'Dropoff': 'ಇಳಿಸುವ ಸ್ಥಳ',
    'Navigate': 'ಮಾರ್ಗದರ್ಶನ',
    'Optional': 'ಐಚ್ಛಿಕ',
    'Required': 'ಅಗತ್ಯವಿದೆ',
    'Invalid': 'ಅಮಾನ್ಯ',
    'Verify': 'ಪರಿಶೀಲಿಸಿ',
    'Camera': 'ಕ್ಯಾಮೆರಾ',
    'Gallery': 'ಗ್ಯಾಲರಿ',
    'Network error: {err}': 'ನೆಟ್‌ವರ್ಕ್ ದೋಷ: {err}',
    'Error: {err}': 'ದೋಷ: {err}',
    'Unexpected error: {err}': 'ಅನಿರೀಕ್ಷಿತ ದೋಷ: {err}',
    'Failed to load (HTTP {code}).': 'ಲೋಡ್ ಮಾಡಲು ವಿಫಲವಾಗಿದೆ (HTTP {code}).',
    'Save failed (HTTP {code}).': 'ಉಳಿಸಲು ವಿಫಲವಾಗಿದೆ (HTTP {code}).',

    // Language Picker & Account Common
    'Language set to ಕನ್ನಡ.': 'ಭಾಷೆಯನ್ನು ಕನ್ನಡಕ್ಕೆ ಬದಲಾಯಿಸಲಾಗಿದೆ.',
    'Language set to English.': 'ಭಾಷೆಯನ್ನು ಇಂಗ್ಲಿಷ್‌ಗೆ ಬದಲಾಯಿಸಲಾಗಿದೆ.',
    'App Language': 'ಅಪ್ಲಿಕೇಶನ್ ಭಾಷೆ',
    'English / ಕನ್ನಡ': 'ಇಂಗ್ಲಿಷ್ / ಕನ್ನಡ',
    'Choose the language used across KisanRider.':
        'ಕಿಸಾನ್‌ರೈಡರ್‌ನಲ್ಲಿ ಬಳಸುವ ಭಾಷೆಯನ್ನು ಆಯ್ಕೆಮಾಡಿ.',
    'English': 'English',
    'Kannada': 'ಕನ್ನಡ',
    'ಕನ್ನಡ': 'ಕನ್ನಡ',

    // Farmer Home & Dashboard
    'Book Transport': 'ಸಾಗಣೆ ಬುಕ್ ಮಾಡಿ',
    'Namaste, {name}': 'ನಮಸ್ತೆ, {name}',
    'IN TRANSIT': 'ಸಾಗಣೆಯಲ್ಲಿದೆ',
    'COMPLETED': 'ಪೂರ್ಣಗೊಂಡಿದೆ',
    'ACTIVE': 'ಸಕ್ರಿಯ',
    'New Request': 'ಹೊಸ ವಿನಂತಿ',
    'Add produce': 'ಬೆಳೆ ಸೇರಿಸಿ',
    'Find Pool': 'ಪೂಲ್ ಹುಡುಕಿ',
    'Nearby farmers': 'ಹತ್ತಿರದ ರೈತರು',
    'Mandi Prices': 'ಮಂಡಿ ಬೆಲೆಗಳು',
    'Compare & earn': 'ಹೋಲಿಸಿ & ಗಳಿಸಿ',
    'Order History': 'ಆರ್ಡರ್ ಇತಿಹಾಸ',
    'View past shipments': 'ಹಿಂದಿನ ಸಾಗಣೆಗಳನ್ನು ನೋಡಿ',
    "TODAY'S TRIPS": 'ಇಂದಿನ ಟ್ರಿಪ್‌ಗಳು',
    'Need help with your shipment?': 'ನಿಮ್ಮ ಸಾಗಣೆಗೆ ಸಹಾಯ ಬೇಕೇ?',
    'Call KisanRider Support': 'ಕಿಸಾನ್‌ರೈಡರ್ ಸಹಾಯವಾಣಿಗೆ ಕರೆ ಮಾಡಿ',
    'Call Support': 'ಸಹಾಯವಾಣಿ ಕರೆ',
    'To: {dropoff}': 'ಇಲ್ಲಿಗೆ: {dropoff}',
    'Pickup OTP: {otp}': 'ಪಿಕಪ್ OTP: {otp}',
    'Track Order': 'ಆರ್ಡರ್ ಟ್ರ್ಯಾಕ್ ಮಾಡಿ',
    'Driver: {name}': 'ಚಾಲಕ: {name}',
    'Awaiting rider': 'ರೈಡರ್‌ಗಾಗಿ ಕಾಯುತ್ತಿದೆ',
    'Delivered': 'ತಲುಪಿಸಲಾಗಿದೆ',
    'Cancelled': 'ರದ್ದುಗೊಂಡಿದೆ',
    'in transit': 'ಸಾಗಣೆಯಲ್ಲಿದೆ',
    'delivered': 'ತಲುಪಿಸಲಾಗಿದೆ',
    'cancelled': 'ರದ್ದುಗೊಂಡಿದೆ',
    'pending': 'ಬಾಕಿ ಇದೆ',
    'No trips yet — post your first request to get started.':
        'ಇನ್ನೂ ಟ್ರಿಪ್‌ಗಳಿಲ್ಲ — ಪ್ರಾರಂಭಿಸಲು ನಿಮ್ಮ ಮೊದಲ ವಿನಂತಿಯನ್ನು ಪೋಸ್ಟ್ ಮಾಡಿ.',
    'Could not load dashboard (HTTP {code}).':
        'ಡ್ಯಾಶ್‌ಬೋರ್ಡ್ ಲೋಡ್ ಮಾಡಲು ವಿಫಲವಾಗಿದೆ (HTTP {code}).',
    'Could not open the dialer.': 'ಡಯಲರ್ ತೆರೆಯಲು ಸಾಧ್ಯವಾಗಲಿಲ್ಲ.',
    'Could not open the phone dialer': 'ಫೋನ್ ಡಯಲರ್ ತೆರೆಯಲು ಸಾಧ್ಯವಾಗಲಿಲ್ಲ',
    'Could not open dialer for {phone}': '{phone} ಗೆ ಡಯಲರ್ ತೆರೆಯಲು ಸಾಧ್ಯವಾಗಲಿಲ್ಲ',
    'Could not open Google Maps': 'ಗೂಗಲ್ ಮ್ಯಾಪ್ಸ್ ತೆರೆಯಲು ಸಾಧ್ಯವಾಗಲಿಲ್ಲ',

    // Farmer Book / Edit Transport
    'New Produce Request': 'ಹೊಸ ಬೆಳೆ ವಿನಂತಿ',
    'Edit Produce Request': 'ಬೆಳೆ ವಿನಂತಿ ತಿದ್ದುಪಡಿ',
    'Update the details below. Only PENDING orders can be edited.':
        'ಕೆಳಗಿನ ವಿವರಗಳನ್ನು ನವೀಕರಿಸಿ. ಬಾಕಿ ಇರುವ ಆರ್ಡರ್‌ಗಳನ್ನು ಮಾತ್ರ ತಿದ್ದುಪಡಿ ಮಾಡಬಹುದು.',
    "Tell us what you're sending and where it needs to go.":
        'ನೀವು ಏನು ಕಳುಹಿಸುತ್ತಿದ್ದೀರಿ ಮತ್ತು ಎಲ್ಲಿಗೆ ಹೋಗಬೇಕು ಎಂದು ತಿಳಿಸಿ.',
    'Crop Name': 'ಬೆಳೆಯ ಹೆಸರು',
    'e.g. Tomatoes': 'ಉದಾ. ಟೊಮೆಟೊ',
    'Crop name is required': 'ಬೆಳೆಯ ಹೆಸರು ಅಗತ್ಯವಿದೆ',
    'Weight / Quantity (in KG)': 'ತೂಕ / ಪ್ರಮಾಣ (ಕೆಜಿಯಲ್ಲಿ)',
    'e.g., 250': 'ಉದಾ. 250',
    'e.g. 250': 'ಉದಾ. 250',
    'Weight is required': 'ತೂಕ ಅಗತ್ಯವಿದೆ',
    'Enter a valid positive weight': 'ಸರಿಯಾದ ತೂಕವನ್ನು ನಮೂದಿಸಿ',
    'Dropoff District': 'ಇಳಿಸುವ ಜಿಲ್ಲೆ',
    'Select a district': 'ಜಿಲ್ಲೆಯನ್ನು ಆಯ್ಕೆಮಾಡಿ',
    'Dropoff Market / APMC Yard': 'ಇಳಿಸುವ ಮಾರುಕಟ್ಟೆ / ಎಪಿಎಂಸಿ ಯಾರ್ಡ್',
    'Select a district first': 'ಮೊದಲು ಜಿಲ್ಲೆಯನ್ನು ಆಯ್ಕೆಮಾಡಿ',
    'Loading markets…': 'ಮಾರುಕಟ್ಟೆಗಳನ್ನು ಲೋಡ್ ಮಾಡುತ್ತಿದೆ…',
    'Select a market': 'ಮಾರುಕಟ್ಟೆಯನ್ನು ಆಯ್ಕೆಮಾಡಿ',
    'Local': 'ಸ್ಥಳೀಯ',
    'Dropoff Shop / Stall Number (optional)':
        'ಅಂಗಡಿ / ಸ್ಟಾಲ್ ಸಂಖ್ಯೆ (ಐಚ್ಛಿಕ)',
    'e.g. Shop #14, Sri Lakshmi Traders': 'ಉದಾ. ಅಂಗಡಿ #14, ಶ್ರೀ ಲಕ್ಷ್ಮಿ ಟ್ರೇಡರ್ಸ್',
    'Pickup Notes': 'ಪಿಕಪ್ ಸೂಚನೆಗಳು',
    'e.g. Behind the canal, near the yellow gate':
        'ಉದಾ. ಕಾಲುವೆಯ ಹಿಂದೆ, ಹಳದಿ ಗೇಟ್ ಹತ್ತಿರ',
    'Pickup location is fixed — contact support to change it.':
        'ಪಿಕಪ್ ಸ್ಥಳ ನಿಗದಿಯಾಗಿದೆ — ಬದಲಾಯಿಸಲು ಸಹಾಯವಾಣಿಯನ್ನು ಸಂಪರ್ಕಿಸಿ.',
    'Pickup Location': 'ಪಿಕಪ್ ಸ್ಥಳ',
    'Current GPS': 'ಪ್ರಸ್ತುತ GPS',
    'Saved Places': 'ಉಳಿಸಿದ ಸ್ಥಳಗಳು',
    'Saved': 'ಉಳಿಸಿದ',
    'Manual': 'ಕೈಯಾರೆ',
    'Detecting your location…': 'ನಿಮ್ಮ ಸ್ಥಳವನ್ನು ಗುರುತಿಸಲಾಗುತ್ತಿದೆ…',
    'Detecting…': 'ಗುರುತಿಸಲಾಗುತ್ತಿದೆ…',
    'Tap "Refresh" to detect your location.':
        'ನಿಮ್ಮ ಸ್ಥಳವನ್ನು ಪಡೆಯಲು "ರಿಫ್ರೆಶ್" ಒತ್ತಿರಿ.',
    'Refresh location': 'ಸ್ಥಳವನ್ನು ರಿಫ್ರೆಶ್ ಮಾಡಿ',
    'Landmark / Pickup Notes': 'ಗುರುತು / ಪಿಕಪ್ ಸೂಚನೆಗಳು',
    'Landmark / Pickup Notes (optional)': 'ಗುರುತು / ಪಿಕಪ್ ಸೂಚನೆಗಳು (ಐಚ್ಛಿಕ)',
    'Landmark (optional)': 'ಗುರುತು (ಐಚ್ಛಿಕ)',
    'No saved places yet. Use Manual Entry and tick "Save this location" to bookmark one for next time.':
        'ಇನ್ನೂ ಉಳಿಸಿದ ಸ್ಥಳಗಳಿಲ್ಲ. ಮುಂದಿನ ಬಾರಿಗೆ ಉಳಿಸಲು ಕೈಯಾರೆ ನಮೂದಿಸಿ.',
    'Saved place': 'ಉಳಿಸಿದ ಸ್ಥಳ',
    'e.g. Opposite the borewell': 'ಉದಾ. ಬೋರ್‌ವೆಲ್ ಎದುರು',
    'Village / Area Name': 'ಗ್ರಾಮ / ಪ್ರದೇಶದ ಹೆಸರು',
    'e.g. Bangarpet, Kolar': 'ಉದಾ. ಬಂಗಾರಪೇಟೆ, ಕೋಲಾರ',
    'e.g. Second gate on the left after the bridge':
        'ಉದಾ. ಸೇತುವೆಯ ನಂತರ ಎಡಭಾಗದ ಎರಡನೇ ಗೇಟ್',
    'Save this location for future bookings':
        'ಭವಿಷ್ಯದ ಬುಕಿಂಗ್‌ಗಳಿಗಾಗಿ ಈ ಸ್ಥಳವನ್ನು ಉಳಿಸಿ',
    'Pickup Window *': 'ಪಿಕಪ್ ಸಮಯದ ಮಿತಿ *',
    'Specify the time window when the rider can arrive for pickup.':
        'ರೈಡರ್ ಪಿಕಪ್‌ಗೆ ಬರಬಹುದಾದ ಸಮಯವನ್ನು ನಿಗದಿಪಡಿಸಿ.',
    'Pickup Window Starts': 'ಪಿಕಪ್ ಆರಂಭದ ಸಮಯ',
    'Pickup Window Ends': 'ಪಿಕಪ್ ಅಂತ್ಯದ ಸಮಯ',
    'Select Date': 'ದಿನಾಂಕ ಆಯ್ಕೆಮಾಡಿ',
    'Select Time': 'ಸಮಯ ಆಯ್ಕೆಮಾಡಿ',
    'Select Date & Time': 'ದಿನಾಂಕ ಮತ್ತು ಸಮಯ ಆಯ್ಕೆಮಾಡಿ',
    'Update Request': 'ವಿನಂತಿ ನವೀಕರಿಸಿ',
    'Submit Request': 'ವಿನಂತಿ ಸಲ್ಲಿಸಿ',
    'Farm Details Required': 'ಕೃಷಿ ವಿವರಗಳು ಅಗತ್ಯವಿದೆ',
    'Before booking transport, please complete your Farm Details (Farm Size > 0 acres and Primary Crops).\n\nBank and UPI details are optional.':
        'ಸಾಗಣೆ ಬುಕ್ ಮಾಡುವ ಮೊದಲು ದಯವಿಟ್ಟು ನಿಮ್ಮ ಕೃಷಿ ವಿವರಗಳನ್ನು ಪೂರ್ಣಗೊಳಿಸಿ (ಜಮೀನಿನ ವಿಸ್ತೀರ್ಣ > 0 ಎಕರೆ ಮತ್ತು ಪ್ರಮುಖ ಬೆಳೆಗಳು).\n\nಬ್ಯಾಂಕ್ ಮತ್ತು UPI ವಿವರಗಳು ಐಚ್ಛಿಕ.',
    'Complete Farm Details': 'ಕೃಷಿ ವಿವರಗಳನ್ನು ಪೂರ್ಣಗೊಳಿಸಿ',
    'Saved Address Required': 'ಉಳಿಸಿದ ವಿಳಾಸ ಅಗತ್ಯವಿದೆ',
    'Before booking transport, you need at least one Saved Farm Address so riders know where to pick up your produce.':
        'ಸಾಗಣೆ ಬುಕ್ ಮಾಡುವ ಮೊದಲು ರೈಡರ್‌ಗಳಿಗೆ ನಿಮ್ಮ ಜಮೀನು ತಿಳಿಯಲು ಕನಿಷ್ಠ ಒಂದು ಉಳಿಸಿದ ವಿಳಾಸ ಅಗತ್ಯವಿದೆ.',
    'Add Farm Address': 'ಜಮೀನಿನ ವಿಳಾಸ ಸೇರಿಸಿ',
    'Request posted. A rider will pick it up soon.':
        'ವಿನಂತಿ ಸಲ್ಲಿಸಲಾಗಿದೆ. ರೈಡರ್ ಶೀಘ್ರದಲ್ಲೇ ಸ್ವೀಕರಿಸುತ್ತಾರೆ.',
    'Order updated successfully.': 'ಆರ್ಡರ್ ಯಶಸ್ವಿಯಾಗಿ ನವೀಕರಿಸಲಾಗಿದೆ.',
    'Please select when the pickup window starts.':
        'ದಯವಿಟ್ಟು ಪಿಕಪ್ ಆರಂಭದ ಸಮಯವನ್ನು ಆಯ್ಕೆಮಾಡಿ.',
    'Please select when the pickup window ends.':
        'ದಯವಿಟ್ಟು ಪಿಕಪ್ ಅಂತ್ಯದ ಸಮಯವನ್ನು ಆಯ್ಕೆಮಾಡಿ.',
    'Pickup window start cannot be in the past.':
        'ಪಿಕಪ್ ಆರಂಭದ ಸಮಯ ಹಿಂದಿನದಾಗಿರಲು ಸಾಧ್ಯವಿಲ್ಲ.',
    'Pickup window end must be later than the start time.':
        'ಪಿಕಪ್ ಅಂತ್ಯದ ಸಮಯ ಆರಂಭದ ಸಮಯಕ್ಕಿಂತ ನಂತರದಾಗಿರಬೇಕು.',
    'Please select a dropoff market.': 'ದಯವಿಟ್ಟು ಇಳಿಸುವ ಮಾರುಕಟ್ಟೆಯನ್ನು ಆಯ್ಕೆಮಾಡಿ.',
    'Location permission denied. Switch to Manual Entry or Saved Places.':
        'ಸ್ಥಳ ಅನುಮತಿ ನಿರಾಕರಿಸಲಾಗಿದೆ. ಕೈಯಾರೆ ಅಥವಾ ಉಳಿಸಿದ ಸ್ಥಳಕ್ಕೆ ಬದಲಾಯಿಸಿ.',
    'Location permission denied. Switch to Manual Entry.':
        'ಸ್ಥಳ ಅನುಮತಿ ನಿರಾಕರಿಸಲಾಗಿದೆ. ಕೈಯಾರೆ ನಮೂದಿಗೆ ಬದಲಾಯಿಸಿ.',
    'GPS location unavailable. Please tap Refresh or switch to Manual Entry / Saved Places.':
        'GPS ಲಭ್ಯವಿಲ್ಲ. ರಿಫ್ರೆಶ್ ಒತ್ತಿರಿ ಅಥವಾ ಕೈಯಾರೆ/ಉಳಿಸಿದ ಸ್ಥಳಕ್ಕೆ ಬದಲಾಯಿಸಿ.',
    'Please pick one of your saved places, or switch to another pickup option.':
        'ದಯವಿಟ್ಟು ಉಳಿಸಿದ ಸ್ಥಳಗಳಲ್ಲಿ ಒಂದನ್ನು ಆಯ್ಕೆಮಾಡಿ.',
    'Please enter the village or area name.': 'ದಯವಿಟ್ಟು ಗ್ರಾಮ ಅಥವಾ ಪ್ರದೇಶದ ಹೆಸರನ್ನು ನಮೂದಿಸಿ.',

    // Farmer Orders & Order Detail & History
    'All': 'ಎಲ್ಲಾ',
    'In Transit': 'ಸಾಗಣೆಯಲ್ಲಿ',
    'Completed': 'ಪೂರ್ಣಗೊಂಡಿದೆ',
    'Failed to load orders (HTTP {code}).':
        'ಆರ್ಡರ್‌ಗಳನ್ನು ಲೋಡ್ ಮಾಡಲು ವಿಫಲವಾಗಿದೆ (HTTP {code}).',
    'No orders match this filter.': 'ಈ ಫಿಲ್ಟರ್‌ಗೆ ಯಾವುದೇ ಆರ್ಡರ್‌ಗಳು ಹೊಂದಿಕೆಯಾಗಿಲ್ಲ.',
    'No active shipments found.': 'ಯಾವುದೇ ಸಕ್ರಿಯ ಸಾಗಣೆಗಳು ಕಂಡುಬಂದಿಲ್ಲ.',
    'Book transport to get started!': 'ಪ್ರಾರಂಭಿಸಲು ಸಾಗಣೆ ಬುಕ್ ಮಾಡಿ!',
    'Could not load orders': 'ಆರ್ಡರ್‌ಗಳನ್ನು ಲೋಡ್ ಮಾಡಲು ಸಾಧ್ಯವಾಗಲಿಲ್ಲ',
    'Dropoff: {dropoff}': 'ಇಳಿಸುವ ಸ್ಥಳ: {dropoff}',
    'Order Details': 'ಆರ್ಡರ್ ವಿವರಗಳು',
    'Edit Request': 'ವಿನಂತಿ ತಿದ್ದುಪಡಿ',
    'Cancel Order': 'ಆರ್ಡರ್ ರದ್ದುಮಾಡಿ',
    'Order {ref}': 'ಆರ್ಡರ್ {ref}',
    'Placed on {date}': '{date} ರಂದು ಸಲ್ಲಿಸಲಾಗಿದೆ',
    'Completed on {date}': '{date} ರಂದು ಪೂರ್ಣಗೊಂಡಿದೆ',
    'Order Specifications': 'ಆರ್ಡರ್ ವಿವರಗಳು',
    'Pickup Window': 'ಪಿಕಪ್ ಸಮಯದ ಮಿತಿ',
    'Pickup Requested': 'ಕೋರಿದ ಪಿಕಪ್ ಸಮಯ',
    'Rider Expected Pickup': 'ರೈಡರ್ ನಿರೀಕ್ಷಿತ ಪಿಕಪ್',
    'Estimated Transport Cost': 'ಅಂದಾಜು ಸಾಗಣೆ ವೆಚ್ಚ',
    'Estimated for a ~10 km trip. Final price is settled at delivery.':
        '~10 ಕಿ.ಮೀ ಟ್ರಿಪ್‌ಗೆ ಅಂದಾಜು ವೆಚ್ಚ. ಅಂತಿಮ ದರ ವಿತರಣೆಯಲ್ಲಿ ನಿರ್ಧರಿಸಲಾಗುತ್ತದೆ.',
    'Assigned Rider': 'ನಿಯೋಜಿತ ರೈಡರ್',
    'Rider Name': 'ರೈಡರ್ ಹೆಸರು',
    'Vehicle Plate': 'ವಾಹನ ಸಂಖ್ಯೆ',
    'Vehicle Type': 'ವಾಹನದ ವಿಧ',
    'CALL RIDER': 'ರೈಡರ್‌ಗೆ ಕರೆ ಮಾಡಿ',
    'Pickup OTP': 'ಪಿಕಪ್ OTP',
    'Share this code with the rider at pickup.':
        'ಪಿಕಪ್ ಸಮಯದಲ್ಲಿ ಈ ಕೋಡ್ ಅನ್ನು ರೈಡರ್‌ಗೆ ನೀಡಿ.',
    'Delivery Progress': 'ವಿತರಣಾ ಪ್ರಗತಿ',
    'Order Placed': 'ಆರ್ಡರ್ ಸಲ್ಲಿಸಲಾಗಿದೆ',
    'Rider Assigned': 'ರೈಡರ್ ನಿಯೋಜಿಸಲಾಗಿದೆ',
    'Payout Breakdown': 'ಪಾವತಿ ವಿವರಣೆ',
    'Settlement will be created once the delivery is completed.':
        'ವಿತರಣೆ ಪೂರ್ಣಗೊಂಡ ನಂತರ ಪಾವತಿ ಲೆಕ್ಕಹಾಕಲಾಗುತ್ತದೆ.',
    'Gross Sale Amount': 'ಒಟ್ಟು ಮಾರಾಟ ಮೊತ್ತ',
    'Pending Calculation': 'ಲೆಕ್ಕಾಚಾರ ಬಾಕಿ ಇದೆ',
    'Transport Fee': 'ಸಾಗಣೆ ಶುಲ್ಕ',
    'Platform Fee': 'ಪ್ಲಾಟ್‌ಫಾರ್ಮ್ ಶುಲ್ಕ',
    'Net Payout': 'ನಿವ್ವಳ ಪಾವತಿ',
    'Crop Rate Applied': 'ಅನ್ವಯಿಸಿದ ಬೆಳೆ ದರ',
    'Live Mandi': 'ಲೈವ್ ಮಂಡಿ',
    'Fallback Standard': 'ಪ್ರಮಾಣಿತ ದರ',
    'Payment Received via Mandi QR ({ref})': 'ಮಂಡಿ QR ಮೂಲಕ ಪಾವತಿ ಸ್ವೀಕರಿಸಲಾಗಿದೆ ({ref})',
    'Payment Received & Settled': 'ಪಾವತಿ ಸ್ವೀಕರಿಸಿ ಇತ್ಯರ್ಥಪಡಿಸಲಾಗಿದೆ',
    'This order was cancelled.': 'ಈ ಆರ್ಡರ್ ಅನ್ನು ರದ್ದುಗೊಳಿಸಲಾಗಿದೆ.',
    'Reason: {reason}': 'ಕಾರಣ: {reason}',
    'Changed my mind': 'ನನ್ನ ಮನಸ್ಸು ಬದಲಾಗಿದೆ',
    'Found alternative transport': 'ಪರ್ಯಾಯ ಸಾಗಣೆ ಸಿಕ್ಕಿದೆ',
    'Crop not ready for pickup': 'ಬೆಳೆ ಪಿಕಪ್‌ಗೆ ಸಿದ್ಧವಾಗಿಲ್ಲ',
    'Price too high': 'ದರ ತುಂಬಾ ಹೆಚ್ಚಾಗಿದೆ',
    'Booking mistake': 'ಬುಕಿಂಗ್ ತಪ್ಪಾಗಿದೆ',
    'Other': 'ಇತರೆ',
    'Cancel Order {ref}?': 'ಆರ್ಡರ್ {ref} ರದ್ದುಗೊಳಿಸಬೇಕೆ?',
    'Please tell us why you are cancelling this order:':
        'ಈ ಆರ್ಡರ್ ಅನ್ನು ಏಕೆ ರದ್ದುಗೊಳಿಸುತ್ತಿದ್ದೀರಿ ಎಂದು ದಯವಿಟ್ಟು ತಿಳಿಸಿ:',
    'Keep Order': 'ಆರ್ಡರ್ ಉಳಿಸಿಕೊಳ್ಳಿ',
    'Order cancelled successfully': 'ಆರ್ಡರ್ ಯಶಸ್ವಿಯಾಗಿ ರದ್ದುಗೊಂಡಿದೆ',
    'Could not cancel order. Please try again.':
        'ಆರ್ಡರ್ ರದ್ದುಗೊಳಿಸಲು ಸಾಧ್ಯವಾಗಲಿಲ್ಲ. ಮತ್ತೆ ಪ್ರಯತ್ನಿಸಿ.',
    'Could not load order': 'ಆರ್ಡರ್ ಲೋಡ್ ಮಾಡಲು ಸಾಧ್ಯವಾಗಲಿಲ್ಲ',
    'Could not load order.': 'ಆರ್ಡರ್ ಲೋಡ್ ಮಾಡಲು ಸಾಧ್ಯವಾಗಲಿಲ್ಲ.',
    'Order not found.': 'ಆರ್ಡರ್ ಕಂಡುಬಂದಿಲ್ಲ.',
    'Failed to load order (HTTP {code}).': 'ಆರ್ಡರ್ ಲೋಡ್ ವಿಫಲವಾಗಿದೆ (HTTP {code}).',
    'No past orders yet.': 'ಇನ್ನೂ ಹಿಂದಿನ ಆರ್ಡರ್‌ಗಳಿಲ್ಲ.',
    'Completed and in-flight shipments will appear here.':
        'ಪೂರ್ಣಗೊಂಡ ಮತ್ತು ನಡೆಯುತ್ತಿರುವ ಸಾಗಣೆಗಳು ಇಲ್ಲಿ ಕಾಣಿಸುತ್ತವೆ.',
    'Could not load order history': 'ಆರ್ಡರ್ ಇತಿಹಾಸ ಲೋಡ್ ಮಾಡಲು ಸಾಧ್ಯವಾಗಲಿಲ್ಲ',
    'Failed to load order history (HTTP {code}).':
        'ಆರ್ಡರ್ ಇತಿಹಾಸ ಲೋಡ್ ವಿಫಲವಾಗಿದೆ (HTTP {code}).',

    // Farmer Earnings
    'Sales Settlement History': 'ಮಾರಾಟ ಪಾವತಿ ಇತಿಹಾಸ',
    'Total Net Sales': 'ಒಟ್ಟು ನಿವ್ವಳ ಮಾರಾಟ',
    'Sum of credited payouts after transport & platform fees':
        'ಸಾಗಣೆ ಮತ್ತು ಪ್ಲಾಟ್‌ಫಾರ್ಮ್ ಶುಲ್ಕ ಕಳೆದ ನಂತರ ಜಮೆಯಾದ ಒಟ್ಟು ಮೊತ್ತ',
    'Pending Calculation — breakdown not yet available.':
        'ಲೆಕ್ಕಾಚಾರ ಬಾಕಿ ಇದೆ — ವಿವರಗಳು ಇನ್ನೂ ಲಭ್ಯವಿಲ್ಲ.',
    'Net Credited Payout': 'ನಿವ್ವಳ ಜಮೆಯಾದ ಪಾವತಿ',
    'No sales settlements found': 'ಯಾವುದೇ ಮಾರಾಟ ಪಾವತಿಗಳು ಕಂಡುಬಂದಿಲ್ಲ',
    'Completed deliveries and their mandi payouts will appear here once the trip is settled.':
        'ಪೂರ್ಣಗೊಂಡ ವಿತರಣೆಗಳು ಮತ್ತು ಮಂಡಿ ಪಾವತಿಗಳು ಇಲ್ಲಿ ಕಾಣಿಸುತ್ತವೆ.',
    'Could not load earnings': 'ಗಳಿಕೆಯನ್ನು ಲೋಡ್ ಮಾಡಲು ಸಾಧ್ಯವಾಗಲಿಲ್ಲ',
    'Failed to load settlements (HTTP {code}).':
        'ಪಾವತಿ ವಿವರ ಲೋಡ್ ವಿಫಲವಾಗಿದೆ (HTTP {code}).',
    'Ref: {ref}': 'ರೆಫರೆನ್ಸ್: {ref}',

    // Mandi Prices
    'All Karnataka': 'ಸಂಪೂರ್ಣ ಕರ್ನಾಟಕ',
    'Search crop (e.g., Arecanut, Pepper, Tomato...)':
        'ಬೆಳೆ ಹುಡುಕಿ (ಉದಾ. ಅಡಿಕೆ, ಮೆಣಸು, ಟೊಮೆಟೊ...)',
    'No APMC rates available right now.': 'ಪ್ರಸ್ತುತ ಯಾವುದೇ APMC ದರಗಳು ಲಭ್ಯವಿಲ್ಲ.',
    'No APMC rates found in {district}.': '{district} ನಲ್ಲಿ ಯಾವುದೇ APMC ದರಗಳು ಕಂಡುಬಂದಿಲ್ಲ.',
    'No APMC rates found for "{query}".': '"{query}" ಗೆ ಯಾವುದೇ APMC ದರಗಳು ಕಂಡುಬಂದಿಲ್ಲ.',
    'No APMC rates found for "{query}" in {district}.':
        '{district} ನಲ್ಲಿ "{query}" ಗೆ ಯಾವುದೇ APMC ದರಗಳು ಕಂಡುಬಂದಿಲ್ಲ.',
    'Could not load prices (HTTP {code}).': 'ಬೆಲೆಗಳನ್ನು ಲೋಡ್ ಮಾಡಲು ವಿಫಲವಾಗಿದೆ (HTTP {code}).',
    'Updated {time}': 'ನವೀಕರಿಸಲಾಗಿದೆ {time}',
    'Min: ₹{min}': 'ಕನಿಷ್ಠ: ₹{min}',
    'Max: ₹{max}': 'ಗರಿಷ್ಠ: ₹{max}',

    // Farmer Account
    'PERSONAL INFORMATION': 'ವೈಯಕ್ತಿಕ ಮಾಹಿತಿ',
    'Edit Profile': 'ಪ್ರೊಫೈಲ್ ತಿದ್ದುಪಡಿ',
    'Name, phone, district & taluk': 'ಹೆಸರು, ಫೋನ್, ಜಿಲ್ಲೆ ಮತ್ತು ತಾಲೂಕು',
    'Farm Details': 'ಕೃಷಿ ವಿವರಗಳು',
    'Farm size and primary crops': 'ಜಮೀನಿನ ವಿಸ್ತೀರ್ಣ ಮತ್ತು ಪ್ರಮುಖ ಬೆಳೆಗಳು',
    'ORDERS & LOGISTICS': 'ಆರ್ಡರ್‌ಗಳು ಮತ್ತು ಸಾಗಣೆ',
    'View past shipments and delivery receipts':
        'ಹಿಂದಿನ ಸಾಗಣೆಗಳು ಮತ್ತು ರಶೀದಿಗಳನ್ನು ನೋಡಿ',
    'LOCATIONS & ADDRESSES': 'ಸ್ಥಳಗಳು ಮತ್ತು ವಿಳಾಸಗಳು',
    'Saved Farm Addresses': 'ಉಳಿಸಿದ ಜಮೀನು ವಿಳಾಸಗಳು',
    'Pickup address and landmark for riders':
        'ರೈಡರ್‌ಗಳಿಗಾಗಿ ಪಿಕಪ್ ವಿಳಾಸ ಮತ್ತು ಗುರುತು',
    'PAYOUTS & BANKING': 'ಪಾವತಿ ಮತ್ತು ಬ್ಯಾಂಕಿಂಗ್',
    'Bank Account & UPI Details': 'ಬ್ಯಾಂಕ್ ಖಾತೆ ಮತ್ತು UPI ವಿವರಗಳು',
    'Where your payouts are credited': 'ನಿಮ್ಮ ಪಾವತಿ ಜಮೆಯಾಗುವ ಖಾತೆ',
    'PREFERENCES & SECURITY': 'ಆದ್ಯತೆಗಳು ಮತ್ತು ಭದ್ರತೆ',
    'Change Password': 'ಪಾಸ್‌ವರ್ಡ್ ಬದಲಾಯಿಸಿ',
    'Verify with an OTP sent to your email':
        'ನಿಮ್ಮ ಇಮೇಲ್‌ಗೆ ಬಂದ OTP ಯೊಂದಿಗೆ ಪರಿಶೀಲಿಸಿ',
    'SUPPORT & LEGAL': 'ಬೆಂಬಲ ಮತ್ತು ನಿಯಮಗಳು',
    'Help & Support': 'ಸಹಾಯ ಮತ್ತು ಬೆಂಬಲ',
    'Terms & Privacy Policy': 'ನಿಯಮಗಳು ಮತ್ತು ಗೌಪ್ಯತಾ ನೀತಿ',
    'District: {district}': 'ಜಿಲ್ಲೆ: {district}',
    'Role: {role}': 'ಪಾತ್ರ: {role}',
    'Your name and contact details as they appear to riders.':
        'ರೈಡರ್‌ಗಳಿಗೆ ಕಾಣಿಸುವ ನಿಮ್ಮ ಹೆಸರು ಮತ್ತು ಸಂಪರ್ಕ ವಿವರಗಳು.',
    'Contact Phone Number': 'ಸಂಪರ್ಕ ಫೋನ್ ಸಂಖ್ಯೆ',
    'Shared with your rider on active trips':
        'ಸಕ್ರಿಯ ಟ್ರಿಪ್‌ಗಳಲ್ಲಿ ನಿಮ್ಮ ರೈಡರ್ ಜೊತೆ ಹಂಚಿಕೊಳ್ಳಲಾಗುತ್ತದೆ',
    'Enter a valid 10-digit mobile number':
        'ಸರಿಯಾದ 10-ಅಂಕಿಯ ಮೊಬೈಲ್ ಸಂಖ್ಯೆಯನ್ನು ನಮೂದಿಸಿ',
    'Contact support to change your login email':
        'ಲಾಗಿನ್ ಇಮೇಲ್ ಬದಲಾಯಿಸಲು ಬೆಂಬಲವನ್ನು ಸಂಪರ್ಕಿಸಿ',
    'Taluk / Village': 'ತಾಲೂಕು / ಗ್ರಾಮ',
    'SAVE PROFILE': 'ಪ್ರೊಫೈಲ್ ಉಳಿಸಿ',
    'Used to estimate loading and crop planning.':
        'ಲೋಡಿಂಗ್ ಮತ್ತು ಬೆಳೆ ಯೋಜನೆಯನ್ನು ಅಂದಾಜು ಮಾಡಲು ಬಳಸಲಾಗುತ್ತದೆ.',
    'Farm Size (acres)': 'ಜಮೀನಿನ ವಿಸ್ತೀರ್ಣ (ಎಕರೆಗಳಲ್ಲಿ)',
    'Enter a valid non-negative number': 'ಸರಿಯಾದ ಸಂಖ್ಯೆಯನ್ನು ನಮೂದಿಸಿ',
    'Primary Crops': 'ಪ್ರಮುಖ ಬೆಳೆಗಳು',
    'e.g. Tomatoes, Beans, Ragi': 'ಉದಾ. ಟೊಮೆಟೊ, ಬೀನ್ಸ್, ರಾಗಿ',
    'Separate multiple crops with commas':
        'ಹಲವು ಬೆಳೆಗಳನ್ನು ಕಾಮಾದಿಂದ ಬೇರ್ಪಡಿಸಿ',
    'SAVE FARM DETAILS': 'ಕೃಷಿ ವಿವರ ಉಳಿಸಿ',
    'Farm Pickup Address': 'ಜಮೀನು ಪಿಕಪ್ ವಿಳಾಸ',
    'Riders use this to find your farm. Be as specific as you can.':
        'ನಿಮ್ಮ ಜಮೀನನ್ನು ಹುಡುಕಲು ರೈಡರ್‌ಗಳು ಇದನ್ನು ಬಳಸುತ್ತಾರೆ. ಸಾಧ್ಯವಾದಷ್ಟು ನಿಖರವಾಗಿ ನಮೂದಿಸಿ.',
    'Farm Address': 'ಜಮೀನು ವಿಳಾಸ',
    'Survey no., village, post office, taluk, district, PIN':
        'ಸರ್ವೆ ಸಂಖ್ಯೆ, ಗ್ರಾಮ, ಅಂಚೆ, ತಾಲೂಕು, ಜಿಲ್ಲೆ, ಪಿನ್',
    'Nearby Landmark': 'ಹತ್ತಿರದ ಗುರುತು',
    'e.g. Opposite the water tank, near the school':
        'ಉದಾ. ನೀರಿನ ಟ್ಯಾಂಕ್ ಎದುರು, ಶಾಲೆಯ ಹತ್ತಿರ',
    'SAVE ADDRESS': 'ವಿಳಾಸ ಉಳಿಸಿ',
    'Payout Details': 'ಪಾವತಿ ವಿವರಗಳು',
    'Where settlements are credited. Either bank or UPI is enough.':
        'ಪಾವತಿ ಜಮೆಯಾಗುವ ವಿವರಗಳು. ಬ್ಯಾಂಕ್ ಅಥವಾ UPI ಒಂದಿದ್ದರೆ ಸಾಕು.',
    'Bank Name': 'ಬ್ಯಾಂಕ್ ಹೆಸರು',
    'e.g. State Bank of India': 'ಉದಾ. ಸ್ಟೇಟ್ ಬ್ಯಾಂಕ್ ಆಫ್ ಇಂಡಿಯಾ',
    'Account Number': 'ಖಾತೆ ಸಂಖ್ಯೆ',
    'IFSC Code': 'IFSC ಕೋಡ್',
    'UPI ID (optional)': 'UPI ಐಡಿ (ಐಚ್ಛಿಕ)',
    'SAVE PAYOUT DETAILS': 'ಪಾವತಿ ವಿವರ ಉಳಿಸಿ',
    'We will email a one-time code to confirm it is you.':
        'ನೀವೇ ಎಂದು ಖಚಿತಪಡಿಸಲು ನಿಮ್ಮ ಇಮೇಲ್‌ಗೆ OTP ಕಳುಹಿಸುತ್ತೇವೆ.',
    'No email on file': 'ಯಾವುದೇ ಇಮೇಲ್ ದಾಖಲಾಗಿಲ್ಲ',
    'No email on file. Please contact support.':
        'ಖಾತೆಯಲ್ಲಿ ಇಮೇಲ್ ಇಲ್ಲ. ದಯವಿಟ್ಟು ಬೆಂಬಲವನ್ನು ಸಂಪರ್ಕಿಸಿ.',
    'OTP sent to {email}': '{email} ಗೆ OTP ಕಳುಹಿಸಲಾಗಿದೆ',
    'Could not send OTP (HTTP {code}).': 'OTP ಕಳುಹಿಸಲು ಸಾಧ್ಯವಾಗಲಿಲ್ಲ (HTTP {code}).',
    'Password change failed (HTTP {code}).':
        'ಪಾಸ್‌ವರ್ಡ್ ಬದಲಾವಣೆ ವಿಫಲವಾಗಿದೆ (HTTP {code}).',
    'Could not load account': 'ಖಾತೆ ಲೋಡ್ ಮಾಡಲು ಸಾಧ್ಯವಾಗಲಿಲ್ಲ',
    'Failed to load account (HTTP {code}).':
        'ಖಾತೆ ಲೋಡ್ ವಿಫಲವಾಗಿದೆ (HTTP {code}).',

    // Pools (Farmer & Rider)
    'Nearby Farmers': 'ಹತ್ತಿರದ ರೈತರು',
    'You need an active PENDING request to start a pool.':
        'ಪೂಲ್ ಪ್ರಾರಂಭಿಸಲು ಬಾಕಿ ಇರುವ (PENDING) ವಿನಂತಿ ಅಗತ್ಯವಿದೆ.',
    'COMPATIBLE REQUESTS': 'ಹೊಂದಾಣಿಕೆಯ ವಿನಂತಿಗಳು',
    'You (Creator)': 'ನೀವು (ರಚನೆಕಾರರು)',
    'No other farmers found nearby.': 'ಹತ್ತಿರದಲ್ಲಿ ಬೇರೆ ರೈತರು ಕಂಡುಬಂದಿಲ್ಲ.',
    'Pooled total:': 'ಒಟ್ಟು ಪೂಲ್ ಪ್ರಮಾಣ:',
    'Est. shared freight:': 'ಅಂದಾಜು ಹಂಚಿದ ಬಾಡಿಗೆ:',
    'Request shared trip': 'ಹಂಚಿದ ಟ್ರಿಪ್ ವಿನಂತಿಸಿ',
    'Create a Pool': 'ಪೂಲ್ ರಚಿಸಿ',
    'Pool Details': 'ಪೂಲ್ ವಿವರಗಳು',
    'Combine your harvest with nearby farmers to share transport costs.':
        'ಸಾಗಣೆ ವೆಚ್ಚ ಹಂಚಿಕೊಳ್ಳಲು ಹತ್ತಿರದ ರೈತರೊಂದಿಗೆ ನಿಮ್ಮ ಬೆಳೆಯನ್ನು ಸೇರಿಸಿ.',
    'Weight (kg)': 'ತೂಕ (ಕೆಜಿ)',
    'Create Pool': 'ಪೂಲ್ ರಚಿಸಿ',
    'Find Pools': 'ಪೂಲ್‌ಗಳನ್ನು ಹುಡುಕಿ',
    'Browse': 'ಹುಡುಕಿ',
    'Created': 'ರಚಿಸಿದವು',
    'Joined': 'ಸೇರಿದವು',
    'No pools found nearby.': 'ಹತ್ತಿರದಲ್ಲಿ ಯಾವುದೇ ಪೂಲ್‌ಗಳು ಕಂಡುಬಂದಿಲ್ಲ.',
    "You haven't created any pools yet.": 'ನೀವು ಇನ್ನೂ ಯಾವುದೇ ಪೂಲ್ ರಚಿಸಿಲ್ಲ.',
    "You haven't joined any pools yet.": 'ನೀವು ಇನ್ನೂ ಯಾವುದೇ ಪೂಲ್‌ಗೆ ಸೇರಿಲ್ಲ.',
    'Start a new pool and invite nearby farmers to share transport!':
        'ಹೊಸ ಪೂಲ್ ಪ್ರಾರಂಭಿಸಿ ಹತ್ತಿರದ ರೈತರನ್ನು ಆಹ್ವಾನಿಸಿ!',
    'Tap the button below to create your first pool.':
        'ನಿಮ್ಮ ಮೊದಲ ಪೂಲ್ ರಚಿಸಲು ಕೆಳಗಿನ ಬಟನ್ ಒತ್ತಿರಿ.',
    'Browse nearby pools to join other farmers.':
        'ಇತರೆ ರೈತರೊಂದಿಗೆ ಸೇರಲು ಹತ್ತಿರದ ಪೂಲ್‌ಗಳನ್ನು ನೋಡಿ.',
    '{count} pools within 10 km': '10 ಕಿ.ಮೀ ಒಳಗೆ {count} ಪೂಲ್‌ಗಳು',
    "{name}'s Pool": '{name} ಅವರ ಪೂಲ್',
    '{distance} km away': '{distance} ಕಿ.ಮೀ ದೂರ',
    'Starts {date}': '{date} ರಂದು ಪ್ರಾರಂಭ',
    'Using approximate location.': 'ಅಂದಾಜು ಸ್ಥಳವನ್ನು ಬಳಸಲಾಗುತ್ತಿದೆ.',
    'Location is required to find nearby pools.':
        'ಹತ್ತಿರದ ಪೂಲ್‌ಗಳನ್ನು ಹುಡುಕಲು ಸ್ಥಳ ಅಗತ್ಯವಿದೆ.',
    'Permission denied': 'ಅನುಮತಿ ನಿರಾಕರಿಸಲಾಗಿದೆ',
    'Successfully joined the pool!': 'ಪೂಲ್‌ಗೆ ಯಶಸ್ವಿಯಾಗಿ ಸೇರಿದ್ದೀರಿ!',
    'Leave Pool?': 'ಪೂಲ್ ಬಿಡಬೇಕೆ?',
    'Are you sure you want to leave this pool? Your produce will not be included in the shared truck.':
        'ನೀವು ಖಚಿತವಾಗಿ ಈ ಪೂಲ್ ಬಿಡಲು ಬಯಸುವಿರಾ? ನಿಮ್ಮ ಬೆಳೆಯನ್ನು ಹಂಚಿದ ವಾಹನದಲ್ಲಿ ಸೇರಿಸಲಾಗುವುದಿಲ್ಲ.',
    'Leave': 'ಬಿಡಿ',
    'You have left the pool.': 'ನೀವು ಪೂಲ್‌ನಿಂದ ಹೊರಬಂದಿದ್ದೀರಿ.',
    'Cancel Pool?': 'ಪೂಲ್ ರದ್ದುಗೊಳಿಸಬೇಕೆ?',
    'Are you sure you want to cancel this pool? All joined farmers will be removed and the pool will be closed.':
        'ಪೂಲ್ ರದ್ದುಗೊಳಿಸಲು ಖಚಿತವೇ? ಸೇರಿದ ಎಲ್ಲಾ ರೈತರನ್ನು ತೆಗೆದುಹಾಕಲಾಗುತ್ತದೆ.',
    'Keep Pool': 'ಪೂಲ್ ಉಳಿಸಿ',
    'Cancel Pool': 'ಪೂಲ್ ರದ್ದುಮಾಡಿ',
    'Cancel My Pool': 'ನನ್ನ ಪೂಲ್ ರದ್ದುಮಾಡಿ',
    'Leave Pool': 'ಪೂಲ್ ಬಿಡಿ',
    'Pool is Full': 'ಪೂಲ್ ತುಂಬಿದೆ',
    'Join Pool': 'ಪೂಲ್ ಸೇರಿ',
    'Confirm & Join': 'ದೃಢೀಕರಿಸಿ ಮತ್ತು ಸೇರಿ',
    'Pool cancelled successfully.': 'ಪೂಲ್ ಯಶಸ್ವಿಯಾಗಿ ರದ್ದುಗೊಂಡಿದೆ.',
    'Members ({count})': 'ಸದಸ್ಯರು ({count})',
    'You ({name})': 'ನೀವು ({name})',
    '{name} (Creator)': '{name} (ರಚನೆಕಾರರು)',
    'Crop Type': 'ಬೆಳೆಯ ವಿಧ',
    'Pickup Area': 'ಪಿಕಪ್ ಪ್ರದೇಶ',
    'Destination': 'ಗಮ್ಯಸ್ಥಾನ',
    'Capacity': 'ಸಾಮರ್ಥ್ಯ',
    'Window': 'ಸಮಯ ಮಿತಿ',
    'YOUR PICKUP OTP': 'ನಿಮ್ಮ ಪಿಕಪ್ OTP',
    'Share this code with the rider when they arrive at your farm.':
        'ರೈಡರ್ ಜಮೀನಿಗೆ ಬಂದಾಗ ಈ ಕೋಡ್ ನೀಡಿ.',
    'Your Pool Payout Breakdown': 'ನಿಮ್ಮ ಪೂಲ್ ಪಾವತಿ ವಿವರಣೆ',
    'Your Transport Share': 'ನಿಮ್ಮ ಸಾಗಣೆ ಪಾಲು',
    'Platform Fee (2%)': 'ಪ್ಲಾಟ್‌ಫಾರ್ಮ್ ಶುಲ್ಕ (2%)',
    'Your Net Payout': 'ನಿಮ್ಮ ನಿವ್ವಳ ಪಾವತಿ',
    'Payment Received ({ref})': 'ಪಾವತಿ ಸ್ವೀಕರಿಸಲಾಗಿದೆ ({ref})',
    'Payment Received & Credited': 'ಪಾವತಿ ಸ್ವೀಕರಿಸಿ ಜಮೆ ಮಾಡಲಾಗಿದೆ',
    'Mandi Destination': 'ಮಂಡಿ ಗಮ್ಯಸ್ಥಾನ',
    'Delivered & settled to your account at {dest}.':
        '{dest} ನಲ್ಲಿ ತಲುಪಿಸಿ ನಿಮ್ಮ ಖಾತೆಗೆ ಇತ್ಯರ್ಥಪಡಿಸಲಾಗಿದೆ.',
    'Your pooled produce has been delivered to {dest}.':
        'ನಿಮ್ಮ ಪೂಲ್ ಬೆಳೆಯನ್ನು {dest} ಗೆ ತಲುಪಿಸಲಾಗಿದೆ.',
    'In Transit to Mandi': 'ಮಂಡಿಗೆ ಸಾಗಣೆಯಲ್ಲಿದೆ',
    'Your produce was picked up and is on the way to {dest}.':
        'ನಿಮ್ಮ ಬೆಳೆಯನ್ನು ಪಿಕಪ್ ಮಾಡಲಾಗಿದೆ ಮತ್ತು {dest} ಕಡೆಗೆ ಸಾಗುತ್ತಿದೆ.',
    'Delivered By': 'ತಲುಪಿಸಿದವರು',
    'Driver Assigned': 'ಚಾಲಕ ನಿಯೋಜಿಸಲಾಗಿದೆ',
    'Name': 'ಹೆಸರು',
    'Vehicle': 'ವಾಹನ',
    'CALL DRIVER': 'ಚಾಲಕನಿಗೆ ಕರೆ ಮಾಡಿ',
    'Estimated Cost': 'ಅಂದಾಜು ವೆಚ್ಚ',
    'Total Pool Freight': 'ಒಟ್ಟು ಪೂಲ್ ಬಾಡಿಗೆ',
    'Your Estimated Share': 'ನಿಮ್ಮ ಅಂದಾಜು ಪಾಲು',
    'No saved places.': 'ಉಳಿಸಿದ ಸ್ಥಳಗಳಿಲ್ಲ.',
    'Tap refresh to detect location.': 'ಸ್ಥಳ ಪಡೆಯಲು ರಿಫ್ರೆಶ್ ಒತ್ತಿರಿ.',
    'Tap refresh.': 'ರಿಫ್ರೆಶ್ ಒತ್ತಿರಿ.',

    // Rider Dashboard, Available, Active, Pool Detail, History, Earnings
    'Individual': 'ವೈಯಕ್ತಿಕ',
    'Pooled': 'ಪೂಲ್',
    'Picked Up': 'ಪಿಕಪ್ ಆಗಿದೆ',
    'Verify OTP': 'OTP ಪರಿಶೀಲಿಸಿ',
    'Verify Pickup': 'ಪಿಕಪ್ ಪರಿಶೀಲಿಸಿ',
    'Enter the 4-digit pickup OTP provided by {name} to confirm produce pickup.':
        '{name} ನೀಡಿದ 4-ಅಂಕಿಯ ಪಿಕಪ್ OTP ನಮೂದಿಸಿ.',
    'Enter a 4-digit numeric OTP.': '4-ಅಂಕಿಯ OTP ನಮೂದಿಸಿ.',
    'Pickup verified for {name}!': '{name} ಅವರಿಗೆ ಪಿಕಪ್ ದೃಢೀಕರಿಸಲಾಗಿದೆ!',
    'Invalid OTP.': 'ತಪ್ಪಾದ OTP.',
    'Invalid OTP. Please check with the farmer.':
        'ತಪ್ಪಾದ OTP. ದಯವಿಟ್ಟು ರೈತರೊಂದಿಗೆ ಪರಿಶೀಲಿಸಿ.',
    'Could not verify OTP. Please try again.':
        'OTP ಪರಿಶೀಲಿಸಲು ಸಾಧ್ಯವಾಗಲಿಲ್ಲ. ಮತ್ತೆ ಪ್ರಯತ್ನಿಸಿ.',
    'Enter the 4-digit OTP.': '4-ಅಂಕಿಯ OTP ನಮೂದಿಸಿ.',
    'PICKUP VERIFICATION': 'ಪಿಕಪ್ ಪರಿಶೀಲನೆ',
    'Ask the farmer for the 4-digit code on their screen.':
        'ರೈತರ ಪರದೆಯಲ್ಲಿರುವ 4-ಅಂಕಿಯ ಕೋಡ್ ಕೇಳಿ.',
    'Confirm & Accept': 'ದೃಢೀಕರಿಸಿ ಮತ್ತು ಒಪ್ಪಿಕೊಳ್ಳಿ',
    'Trip Accepted!': 'ಟ್ರಿಪ್ ಒಪ್ಪಿಕೊಳ್ಳಲಾಗಿದೆ!',
    'Pool Accepted!': 'ಪೂಲ್ ಒಪ್ಪಿಕೊಳ್ಳಲಾಗಿದೆ!',
    'Pool Accepted! Trips created for each member.':
        'ಪೂಲ್ ಒಪ್ಪಿಕೊಳ್ಳಲಾಗಿದೆ! ಪ್ರತಿ ಸದಸ್ಯರಿಗೂ ಟ್ರಿಪ್ ರಚಿಸಲಾಗಿದೆ.',
    'Could not accept.': 'ಒಪ್ಪಿಕೊಳ್ಳಲು ಸಾಧ್ಯವಾಗಲಿಲ್ಲ.',
    'Could not accept pool.': 'ಪೂಲ್ ಒಪ್ಪಿಕೊಳ್ಳಲು ಸಾಧ್ಯವಾಗಲಿಲ್ಲ.',
    'Set Expected Pickup Time': 'ನಿರೀಕ್ಷಿತ ಪಿಕಪ್ ಸಮಯ ನಿಗದಿಪಡಿಸಿ',
    "Farmer's Pickup Window:": 'ರೈತರ ಪಿಕಪ್ ಸಮಯ ಮಿತಿ:',
    'Your Expected Arrival:': 'ನಿಮ್ಮ ನಿರೀಕ್ಷಿತ ಆಗಮನ:',
    'Cannot be earlier than window start ({time}).':
        'ಆರಂಭದ ಸಮಯ ({time}) ಕ್ಕಿಂತ ಮುಂಚಿತವಾಗಿರಲು ಸಾಧ್ಯವಿಲ್ಲ.',
    'Cannot be later than window end ({time}).':
        'ಅಂತ್ಯದ ಸಮಯ ({time}) ಕ್ಕಿಂತ ನಂತರದಾಗಿರಲು ಸಾಧ್ಯವಿಲ್ಲ.',
    'No open pools nearby': 'ಹತ್ತಿರದಲ್ಲಿ ತೆರೆದ ಪೂಲ್‌ಗಳಿಲ್ಲ',
    'No requests found nearby': 'ಹತ್ತಿರದಲ್ಲಿ ವಿನಂತಿಗಳು ಕಂಡುಬಂದಿಲ್ಲ',
    'There are currently no available pooled transportation requests in your area. Please check again later.':
        'ನಿಮ್ಮ ಪ್ರದೇಶದಲ್ಲಿ ಪ್ರಸ್ತುತ ಯಾವುದೇ ಪೂಲ್ ವಿನಂತಿಗಳಿಲ್ಲ. ನಂತರ ಪರಿಶೀಲಿಸಿ.',
    'There are currently no available transportation requests in your area. Please check again later.':
        'ನಿಮ್ಮ ಪ್ರದೇಶದಲ್ಲಿ ಪ್ರಸ್ತುತ ಯಾವುದೇ ಸಾಗಣೆ ವಿನಂತಿಗಳಿಲ್ಲ. ನಂತರ ಪರಿಶೀಲಿಸಿ.',
    'Location needed to show nearby requests':
        'ಹತ್ತಿರದ ವಿನಂತಿಗಳನ್ನು ತೋರಿಸಲು ಸ್ಥಳ ಅನುಮತಿ ಅಗತ್ಯವಿದೆ',
    'Open Settings': 'ಸೆಟ್ಟಿಂಗ್‌ಗಳನ್ನು ತೆರೆಯಿರಿ',
    'I have enabled it — retry': 'ಆನ್ ಮಾಡಿದ್ದೇನೆ — ಮತ್ತೆ ಪ್ರಯತ್ನಿಸಿ',
    'Could not determine your location.': 'ನಿಮ್ಮ ಸ್ಥಳವನ್ನು ಗುರುತಿಸಲು ಸಾಧ್ಯವಾಗಲಿಲ್ಲ.',
    'Could not determine location. Please enable GPS.':
        'ಸ್ಥಳ ಗುರುತಿಸಲು ಸಾಧ್ಯವಾಗಲಿಲ್ಲ. ದಯವಿಟ್ಟು GPS ಆನ್ ಮಾಡಿ.',
    'View Route': 'ಮಾರ್ಗ ನೋಡಿ',
    'This request has expired as the pickup window has ended.':
        'ಪಿಕಪ್ ಸಮಯ ಮೀರಿದ ಕಾರಣ ಈ ವಿನಂತಿ ಅವಧಿ ಮುಗಿದಿದೆ.',
    'No active trips. Accept a request to get started.':
        'ಸಕ್ರಿಯ ಟ್ರಿಪ್‌ಗಳಿಲ್ಲ. ಪ್ರಾರಂಭಿಸಲು ವಿನಂತಿಯನ್ನು ಸ್ವೀಕರಿಸಿ.',
    'No active pooled trips.': 'ಸಕ್ರಿಯ ಪೂಲ್ ಟ್ರಿಪ್‌ಗಳಿಲ್ಲ.',
    'No trips match this filter.': 'ಈ ಫಿಲ್ಟರ್‌ಗೆ ಟ್ರಿಪ್‌ಗಳಿಲ್ಲ.',
    'Cancel this trip?': 'ಈ ಟ್ರಿಪ್ ರದ್ದುಗೊಳಿಸಬೇಕೆ?',
    'The farmer will be notified and the request will go back to the Available feed for another rider to accept. This cannot be undone.':
        'ರೈತರಿಗೆ ತಿಳಿಸಲಾಗುತ್ತದೆ ಮತ್ತು ವಿನಂತಿ ಮತ್ತೆ ಲಭ್ಯ ಪಟ್ಟಿಗೆ ಹೋಗುತ್ತದೆ.',
    'Keep Trip': 'ಟ್ರಿಪ್ ಉಳಿಸಿ',
    'Cancel Trip': 'ಟ್ರಿಪ್ ರದ್ದುಮಾಡಿ',
    'Reject / Cancel Trip': 'ತಿರಸ್ಕರಿಸಿ / ರದ್ದುಮಾಡಿ',
    'Could not cancel the trip. Please try again.':
        'ಟ್ರಿಪ್ ರದ್ದುಗೊಳಿಸಲು ಸಾಧ್ಯವಾಗಲಿಲ್ಲ. ಮತ್ತೆ ಪ್ರಯತ್ನಿಸಿ.',
    'Dropoff — Mandi Unloading': 'ಇಳಿಸುವುದು — ಮಂಡಿ ಅನ್‌ಲೋಡ್',
    'Mandi': 'ಮಂಡಿ',
    'Stall': 'ಸ್ಟಾಲ್',
    'Navigate to Mandi': 'ಮಂಡಿಗೆ ಮಾರ್ಗದರ್ಶನ',
    'Cancellation is locked after pickup verification.':
        'ಪಿಕಪ್ ದೃಢೀಕರಣದ ನಂತರ ರದ್ದುಗೊಳಿಸಲು ಸಾಧ್ಯವಿಲ್ಲ.',
    'Completing…': 'ಪೂರ್ಣಗೊಳಿಸುತ್ತಿದೆ…',
    '✅ Mark as Delivered / Unloaded': '✅ ತಲುಪಿಸಲಾಗಿದೆ / ಇಳಿಸಲಾಗಿದೆ ಎಂದು ಗುರುತಿಸಿ',
    'Delivery & Payment Complete': 'ವಿತರಣೆ ಮತ್ತು ಪಾವತಿ ಪೂರ್ಣಗೊಂಡಿದೆ',
    'Delivery Complete': 'ವಿತರಣೆ ಪೂರ್ಣಗೊಂಡಿದೆ',
    'Delivered to': 'ತಲುಪಿಸಿದ ಸ್ಥಳ',
    'Completed on': 'ಪೂರ್ಣಗೊಂಡ ದಿನಾಂಕ',
    'Reference': 'ರೆಫರೆನ್ಸ್',
    'Payment Ref': 'ಪಾವತಿ ರೆಫರೆನ್ಸ್',
    'PAYMENT BREAKDOWN': 'ಪಾವತಿ ವಿವರಣೆ',
    'PAID ✅': 'ಪಾವತಿಸಲಾಗಿದೆ ✅',
    'PENDING QR': 'QR ಬಾಕಿ ಇದೆ',
    'Total Value': 'ಒಟ್ಟು ಮೌಲ್ಯ',
    'Rider Fare': 'ರೈಡರ್ ಬಾಡಿಗೆ',
    'Farmer Gets': 'ರೈತರಿಗೆ ಸಿಗುವ ಮೊತ್ತ',
    'Generate Payment QR': 'ಪಾವತಿ QR ರಚಿಸಿ',
    'Payment done! Earnings updated under your Earnings tab.':
        'ಪಾವತಿ ಮುಗಿದಿದೆ! ನಿಮ್ಮ ಗಳಿಕೆ ಟ್ಯಾಬ್ ನವೀಕರಿಸಲಾಗಿದೆ.',
    'Payment received! Rider & Farmer accounts updated.':
        'ಪಾವತಿ ಸ್ವೀಕರಿಸಲಾಗಿದೆ! ರೈಡರ್ ಮತ್ತು ರೈತರ ಖಾತೆ ನವೀಕರಿಸಲಾಗಿದೆ.',
    'Pool payment received! Auto-split complete.':
        'ಪೂಲ್ ಪಾವತಿ ಸ್ವೀಕರಿಸಲಾಗಿದೆ! ಸ್ವಯಂ ವಿಭಜನೆ ಪೂರ್ಣ.',
    'Farmer Contact': 'ರೈತರ ಸಂಪರ್ಕ',
    '📞 CALL FARMER': '📞 ರೈತರಿಗೆ ಕರೆ ಮಾಡಿ',
    'CALL FARMER': 'ರೈತರಿಗೆ ಕರೆ ಮಾಡಿ',
    'Tap to view map & stops': 'ನಕ್ಷೆ ಮತ್ತು ನಿಲ್ದಾಣಗಳನ್ನು ನೋಡಲು ಒತ್ತಿರಿ',
    '{crop} (Pooled Trip)': '{crop} (ಪೂಲ್ ಟ್ರಿಪ್)',
    'Combined: {weight} kg': 'ಒಟ್ಟು ತೂಕ: {weight} ಕೆಜಿ',
    '{count} Farmer Pickups': '{count} ರೈತರ ಪಿಕಪ್‌ಗಳು',
    'Pickup Progress: {done} of {total} completed':
        'ಪಿಕಪ್ ಪ್ರಗತಿ: {total} ರಲ್ಲಿ {done} ಪೂರ್ಣಗೊಂಡಿದೆ',
    'Destination: {dest}': 'ಗಮ್ಯಸ್ಥಾನ: {dest}',
    'Payment Done ✅': 'ಪಾವತಿ ಪೂರ್ಣ ✅',

    // Rider Pool Route Optimization
    'Active Pool Route': 'ಸಕ್ರಿಯ ಪೂಲ್ ಮಾರ್ಗ',
    'Pool Details & Route': 'ಪೂಲ್ ವಿವರ ಮತ್ತು ಮಾರ್ಗ',
    'Refresh Route': 'ಮಾರ್ಗ ರಿಫ್ರೆಶ್ ಮಾಡಿ',
    'Computing optimal road pickup sequence…':
        'ಉತ್ತಮ ಪಿಕಪ್ ಮಾರ್ಗವನ್ನು ಲೆಕ್ಕಹಾಕುತ್ತಿದೆ…',
    'Road Network Route': 'ರಸ್ತೆ ಮಾರ್ಗದ ವಿವರ',
    'Est. Time': 'ಅಂದಾಜು ಸಮಯ',
    'Combined': 'ಒಟ್ಟು ತೂಕ',
    'COMMON DROPOFF MARKET': 'ಸಾಮಾನ್ಯ ಮಂಡಿ ಮಾರುಕಟ್ಟೆ',
    'POOL PAYMENT BREAKDOWN': 'ಪೂಲ್ ಪಾವತಿ ವಿವರಣೆ',
    'Total Crop Sale': 'ಒಟ್ಟು ಬೆಳೆ ಮಾರಾಟ',
    'Rider Transport Fare': 'ರೈಡರ್ ಸಾಗಣೆ ಬಾಡಿಗೆ',
    'Farmers Net Payout': 'ರೈತರ ನಿವ್ವಳ ಪಾವತಿ',
    'Exceeds Vehicle Capacity': 'ವಾಹನದ ಸಾಮರ್ಥ್ಯಕ್ಕಿಂತ ಹೆಚ್ಚು',
    'Pool Delivered & Paid ({ref})': 'ಪೂಲ್ ತಲುಪಿಸಿ ಪಾವತಿಸಲಾಗಿದೆ ({ref})',
    'Pool Delivered — Payment Done': 'ಪೂಲ್ ತಲುಪಿಸಲಾಗಿದೆ — ಪಾವತಿ ಪೂರ್ಣ',
    'Pool marked as delivered! Tap Generate Payment QR to collect payment.':
        'ಪೂಲ್ ತಲುಪಿಸಲಾಗಿದೆ! ಹಣ ಸಂಗ್ರಹಿಸಲು ಪಾವತಿ QR ರಚಿಸಿ.',
    'Take a photo of the delivered pooled produce at the mandi. This marks all pooled pickups as delivered.':
        'ಮಂಡಿಯಲ್ಲಿ ಇಳಿಸಿದ ಪೂಲ್ ಬೆಳೆಯ ಫೋಟೋ ತೆಗೆಯಿರಿ. ಇದು ಎಲ್ಲಾ ಪಿಕಪ್‌ಗಳನ್ನು ತಲುಪಿಸಿದಂತೆ ಗುರುತಿಸುತ್ತದೆ.',
    'Optimized Pickup Sequence ({count} Farmers)':
        'ಉತ್ತಮ ಪಿಕಪ್ ಕ್ರಮ ({count} ರೈತರು)',
    'Verify Pickups ({done}/{total}) to Deliver':
        'ತಲುಪಿಸಲು ಪಿಕಪ್‌ಗಳನ್ನು ಪರಿಶೀಲಿಸಿ ({done}/{total})',
    'Farm Gate': 'ಜಮೀನು ಗೇಟ್',
    'Pending Pickup': 'ಪಿಕಪ್ ಬಾಕಿ ಇದೆ',
    'Location: Coordinates missing (Address provided)':
        'ಸ್ಥಳ: ಅಕ್ಷಾಂಶವಿಲ್ಲ (ವಿಳಾಸ ನೀಡಲಾಗಿದೆ)',
    'Requested: {time}': 'ಕೋರಿದ ಸಮಯ: {time}',
    'Landmark: {landmark}': 'ಗುರುತು: {landmark}',

    // Delivery Photo Dialog
    'Upload Delivery Proof': 'ವಿತರಣಾ ಸಾಕ್ಷ್ಯ ಅಪ್‌ಲೋಡ್ ಮಾಡಿ',
    'Upload Proof of Delivery': 'ವಿತರಣಾ ಸಾಕ್ಷ್ಯ ಸಲ್ಲಿಸಿ',
    'Take a photo of the delivered crates at the mandi. This is required before the trip can be completed.':
        'ಮಂಡಿಯಲ್ಲಿ ತಲುಪಿಸಿದ ಕ್ರೇಟ್‌ಗಳ ಫೋಟೋ ತೆಗೆಯಿರಿ. ಟ್ರಿಪ್ ಪೂರ್ಣಗೊಳಿಸಲು ಇದು ಅಗತ್ಯವಿದೆ.',
    'Uploading proof of delivery…': 'ವಿತರಣಾ ಫೋಟೋ ಅಪ್‌ಲೋಡ್ ಆಗುತ್ತಿದೆ…',
    'Uploading…': 'ಅಪ್‌ಲೋಡ್ ಆಗುತ್ತಿದೆ…',
    'Please attach a photo first.': 'ದಯವಿಟ್ಟು ಮೊದಲು ಫೋಟೋ ಲಗತ್ತಿಸಿ.',
    'Photo upload failed.': 'ಫೋಟೋ ಅಪ್‌ಲೋಡ್ ವಿಫಲವಾಗಿದೆ.',
    'Photo upload failed (HTTP {code}).': 'ಫೋಟೋ ಅಪ್‌ಲೋಡ್ ವಿಫಲವಾಗಿದೆ (HTTP {code}).',
    'Could not complete delivery. Please try again.':
        'ವಿತರಣೆ ಪೂರ್ಣಗೊಳಿಸಲು ಸಾಧ್ಯವಾಗಲಿಲ್ಲ. ಮತ್ತೆ ಪ್ರಯತ್ನಿಸಿ.',
    'Connection timed out. Please check backend server.':
        'ಸಂಪರ್ಕ ಸಮಯ ಮೀರಿದೆ. ಸರ್ವರ್ ಪರಿಶೀಲಿಸಿ.',

    // Rider Earnings, Trip History, Trip Detail, Account
    'Recent Trip History': 'ಇತ್ತೀಚಿನ ಟ್ರಿಪ್ ಇತಿಹಾಸ',
    "Today's Earnings": 'ಇಂದಿನ ಗಳಿಕೆ',
    '{count} completed trip': '{count} ಪೂರ್ಣಗೊಂಡ ಟ್ರಿಪ್',
    '{count} completed trips': '{count} ಪೂರ್ಣಗೊಂಡ ಟ್ರಿಪ್‌ಗಳು',
    'No completed trips yet': 'ಇನ್ನೂ ಪೂರ್ಣಗೊಂಡ ಟ್ರಿಪ್‌ಗಳಿಲ್ಲ',
    'No completed trips yet.': 'ಇನ್ನೂ ಪೂರ್ಣಗೊಂಡ ಟ್ರಿಪ್‌ಗಳಿಲ್ಲ.',
    'Completed deliveries will appear here along with their payout amounts.':
        'ಪೂರ್ಣಗೊಂಡ ವಿತರಣೆಗಳು ಮತ್ತು ಅವುಗಳ ಬಾಡಿಗೆ ಮೊತ್ತ ಇಲ್ಲಿ ಕಾಣಿಸುತ್ತವೆ.',
    'Delivered and cancelled trips will appear here once you start accepting requests.':
        'ನೀವು ಟ್ರಿಪ್‌ಗಳನ್ನು ಸ್ವೀಕರಿಸಲು ಪ್ರಾರಂಭಿಸಿದ ನಂತರ ಇಲ್ಲಿ ಕಾಣಿಸುತ್ತವೆ.',
    'Failed to load earnings (HTTP {code}).':
        'ಗಳಿಕೆ ಲೋಡ್ ಮಾಡಲು ವಿಫಲವಾಗಿದೆ (HTTP {code}).',
    'Trip History': 'ಟ್ರಿಪ್ ಇತಿಹಾಸ',
    'WALLET CREDITED': 'ವಾಲೆಟ್‌ಗೆ ಜಮೆ',
    'CASH COLLECTED': 'ನಗದು ಸಂಗ್ರಹಿಸಲಾಗಿದೆ',
    'Could not load trip history': 'ಟ್ರಿಪ್ ಇತಿಹಾಸ ಲೋಡ್ ಮಾಡಲು ಸಾಧ್ಯವಾಗಲಿಲ್ಲ',
    'Failed to load trip history (HTTP {code}).':
        'ಟ್ರಿಪ್ ಇತಿಹಾಸ ಲೋಡ್ ವಿಫಲವಾಗಿದೆ (HTTP {code}).',
    'Trip Details': 'ಟ್ರಿಪ್ ವಿವರಗಳು',
    'Trip Cancelled': 'ಟ್ರಿಪ್ ರದ್ದುಗೊಂಡಿದೆ',
    'Trip Completed': 'ಟ್ರಿಪ್ ಪೂರ್ಣಗೊಂಡಿದೆ',
    'Trip {ref}': 'ಟ್ರಿಪ್ {ref}',
    'Ended on': 'ಮುಗಿದ ದಿನಾಂಕ',
    'Delivered on': 'ತಲುಪಿಸಿದ ದಿನಾಂಕ',
    'Farmer Info': 'ರೈತರ ಮಾಹಿತಿ',
    'Phone': 'ಫೋನ್',
    'Mandi Unloading': 'ಮಂಡಿ ಇಳಿಸುವ ಸ್ಥಳ',
    'APMC Mandi': 'APMC ಮಂಡಿ',
    'Trader Name': 'ವ್ಯಾಪಾರಿಯ ಹೆಸರು',
    'Stall Number': 'ಸ್ಟಾಲ್ ಸಂಖ್ಯೆ',
    'Crop Load': 'ಬೆಳೆ ಲೋಡ್',
    'Total Weight': 'ಒಟ್ಟು ತೂಕ',
    'Fare & Earnings': 'ಬಾಡಿಗೆ ಮತ್ತು ಗಳಿಕೆ',
    'No fare was earned on this trip — it was cancelled before delivery.':
        'ವಿತರಣೆಗೂ ಮುನ್ನ ರದ್ದಾದ ಕಾರಣ ಈ ಟ್ರಿಪ್‌ನಲ್ಲಿ ಯಾವುದೇ ಬಾಡಿಗೆ ಗಳಿಸಿಲ್ಲ.',
    'Fare breakdown is not available for this trip.':
        'ಈ ಟ್ರಿಪ್‌ಗೆ ಬಾಡಿಗೆ ವಿವರ ಲಭ್ಯವಿಲ್ಲ.',
    'Gross Transport Fare': 'ಒಟ್ಟು ಸಾಗಣೆ ಬಾಡಿಗೆ',
    'Platform Commission': 'ಪ್ಲಾಟ್‌ಫಾರ್ಮ್ ಕಮಿಷನ್',
    'Net Earnings': 'ನಿವ್ವಳ ಗಳಿಕೆ',
    'MANDI SALE SPLIT': 'ಮಂಡಿ ಮಾರಾಟ ವಿಭಜನೆ',
    'Total Crop Value': 'ಒಟ್ಟು ಬೆಳೆ ಮೌಲ್ಯ',
    'QR PAYMENT AT MANDI': 'ಮಂಡಿಯಲ್ಲಿ QR ಪಾವತಿ',
    'CASH IN HAND': 'ಕೈಯಲ್ಲಿ ನಗದು',
    'Could not load trip': 'ಟ್ರಿಪ್ ಲೋಡ್ ಮಾಡಲು ಸಾಧ್ಯವಾಗಲಿಲ್ಲ',
    'Could not load trip.': 'ಟ್ರಿಪ್ ಲೋಡ್ ಮಾಡಲು ಸಾಧ್ಯವಾಗಲಿಲ್ಲ.',
    'Trip not found.': 'ಟ್ರಿಪ್ ಕಂಡುಬಂದಿಲ್ಲ.',
    'Failed to load trip (HTTP {code}).': 'ಟ್ರಿಪ್ ಲೋಡ್ ವಿಫಲವಾಗಿದೆ (HTTP {code}).',
    'Account Settings': 'ಖಾತೆ ಸೆಟ್ಟಿಂಗ್‌ಗಳು',
    'Driver Profile features coming soon': 'ಚಾಲಕ ಪ್ರೊಫೈಲ್ ವೈಶಿಷ್ಟ್ಯಗಳು ಶೀಘ್ರದಲ್ಲೇ ಬರಲಿವೆ',
    'Personal Info (Full Name)': 'ವೈಯಕ್ತಿಕ ಮಾಹಿತಿ (ಪೂರ್ಣ ಹೆಸರು)',
    'Operating District': 'ಕಾರ್ಯನಿರ್ವಹಿಸುವ ಜಿಲ್ಲೆ',
    'Vehicle Registration Number': 'ವಾಹನ ನೋಂದಣಿ ಸಂಖ್ಯೆ',
    'Payload Capacity (> 0 kg)': 'ಭಾರ ಸಾಮರ್ಥ್ಯ (> 0 ಕೆಜಿ)',
    'Driving Licence Number': 'ಡ್ರೈವಿಂಗ್ ಲೈಸೆನ್ಸ್ ಸಂಖ್ಯೆ',
    'Operating Routes / Coverage Area': 'ಕಾರ್ಯನಿರ್ವಹಿಸುವ ಮಾರ್ಗಗಳು / ಪ್ರದೇಶ',
    'Complete Profile to Go On-Duty': 'ಡ್ಯೂಟಿಗೆ ಸೇರಲು ಪ್ರೊಫೈಲ್ ಪೂರ್ಣಗೊಳಿಸಿ',
    'Before you can go On-Duty and accept trips, please complete the following mandatory profile details:':
        'ಡ್ಯೂಟಿಗೆ ಬಂದು ಟ್ರಿಪ್ ಸ್ವೀಕರಿಸುವ ಮೊದಲು ದಯವಿಟ್ಟು ಈ ಕಡ್ಡಾಯ ವಿವರಗಳನ್ನು ಪೂರ್ಣಗೊಳಿಸಿ:',
    'Note: Bank details and UPI ID are optional.':
        'ಸೂಚನೆ: ಬ್ಯಾಂಕ್ ವಿವರಗಳು ಮತ್ತು UPI ಐಡಿ ಐಚ್ಛಿಕ.',
    'You are now On-Duty — accepting trips.':
        'ನೀವು ಈಗ ಆನ್-ಡ್ಯೂಟಿಯಲ್ಲಿದ್ದೀರಿ — ಟ್ರಿಪ್‌ಗಳನ್ನು ಸ್ವೀಕರಿಸುತ್ತಿದ್ದೀರಿ.',
    'You are now Offline — no new trips will appear.':
        'ನೀವು ಈಗ ಆಫ್‌ಲೈನ್‌ನಲ್ಲಿದ್ದೀರಿ — ಹೊಸ ಟ್ರಿಪ್‌ಗಳು ಕಾಣಿಸುವುದಿಲ್ಲ.',
    'Could not update duty status (HTTP {code}).':
        'ಡ್ಯೂಟಿ ಸ್ಥಿತಿ ಬದಲಾಯಿಸಲು ವಿಫಲವಾಗಿದೆ (HTTP {code}).',
    'Name, phone & base district': 'ಹೆಸರು, ಫೋನ್ ಮತ್ತು ಮೂಲ ಜಿಲ್ಲೆ',
    'VEHICLE & DRIVER DETAILS': 'ವಾಹನ ಮತ್ತು ಚಾಲಕ ವಿವರಗಳು',
    'Vehicle & License Info': 'ವಾಹನ ಮತ್ತು ಲೈಸೆನ್ಸ್ ಮಾಹಿತಿ',
    'License, model, plate number, payload':
        'ಲೈಸೆನ್ಸ್, ಮಾದರಿ, ನಂಬರ್ ಪ್ಲೇಟ್, ಭಾರ ಸಾಮರ್ಥ್ಯ',
    'SERVICE AREA & ROUTES': 'ಸೇವಾ ಪ್ರದೇಶ ಮತ್ತು ಮಾರ್ಗಗಳು',
    'Operating Districts & Routes': 'ಕಾರ್ಯನಿರ್ವಹಿಸುವ ಜಿಲ್ಲೆಗಳು ಮತ್ತು ಮಾರ್ಗಗಳು',
    'Where you want to haul': 'ನೀವು ಎಲ್ಲಿ ಸಾಗಣೆ ಮಾಡಲು ಬಯಸುತ್ತೀರಿ',
    'TRIPS & EARNINGS': 'ಟ್ರಿಪ್‌ಗಳು ಮತ್ತು ಗಳಿಕೆ',
    'Past deliveries, fares earned & cash records':
        'ಹಿಂದಿನ ವಿತರಣೆಗಳು, ಗಳಿಸಿದ ಬಾಡಿಗೆ ಮತ್ತು ನಗದು ದಾಖಲೆ',
    'Where trip earnings are settled': 'ಟ್ರಿಪ್ ಗಳಿಕೆ ಜಮೆಯಾಗುವ ಖಾತೆ',
    'Rider Helpline & Support': 'ರೈಡರ್ ಸಹಾಯವಾಣಿ ಮತ್ತು ಬೆಂಬಲ',
    'Rider Helpline': 'ರೈಡರ್ ಸಹಾಯವಾಣಿ',
    'Terms & Transport Rules': 'ನಿಯಮಗಳು ಮತ್ತು ಸಾಗಣೆ ನಿಯಮಾವಳಿ',
    'Transport Rules & Terms': 'ಸಾಗಣೆ ನಿಯಮಗಳು',
    'On-Duty Status': 'ಡ್ಯೂಟಿ ಸ್ಥಿತಿ',
    'Available for Trips': 'ಟ್ರಿಪ್‌ಗಳಿಗೆ ಲಭ್ಯ',
    'Offline': 'ಆಫ್‌ಲೈನ್',
    'Base District': 'ಮೂಲ ಜಿಲ್ಲೆ',
    'Base District: {district}': 'ಮೂಲ ಜಿಲ್ಲೆ: {district}',
    'Your name and contact details as they appear to farmers.':
        'ರೈತರಿಗೆ ಕಾಣಿಸುವ ನಿಮ್ಮ ಹೆಸರು ಮತ್ತು ಸಂಪರ್ಕ ವಿವರಗಳು.',
    'Shared with the farmer on active trips':
        'ಸಕ್ರಿಯ ಟ್ರಿಪ್‌ಗಳಲ್ಲಿ ರೈತರೊಂದಿಗೆ ಹಂಚಿಕೊಳ್ಳಲಾಗುತ್ತದೆ',
    'Shown to farmers so they know what kind of vehicle to expect.':
        'ಯಾವ ವಾಹನ ಬರುತ್ತದೆ ಎಂದು ರೈತರಿಗೆ ತಿಳಿಯಲು ತೋರಿಸಲಾಗುತ್ತದೆ.',
    'Driving License Number': 'ಡ್ರೈವಿಂಗ್ ಲೈಸೆನ್ಸ್ ಸಂಖ್ಯೆ',
    'Vehicle Model': 'ವಾಹನ ಮಾದರಿ',
    'Vehicle Plate Number': 'ವಾಹನ ನಂಬರ್ ಪ್ಲೇಟ್',
    'Max Payload Capacity': 'ಗರಿಷ್ಠ ಭಾರ ಸಾಮರ್ಥ್ಯ',
    'Total weight your vehicle can safely carry':
        'ನಿಮ್ಮ ವಾಹನ ಸುರಕ್ಷಿತವಾಗಿ ಸಾಗಿಸಬಹುದಾದ ಒಟ್ಟು ತೂಕ',
    'SAVE VEHICLE DETAILS': 'ವಾಹನ ವಿವರ ಉಳಿಸಿ',
    'You will only see trips that start in these districts. Leave blank to see everything.':
        'ಈ ಜಿಲ್ಲೆಗಳಿಂದ ಪ್ರಾರಂಭವಾಗುವ ಟ್ರಿಪ್‌ಗಳು ಮಾತ್ರ ನಿಮಗೆ ಕಾಣಿಸುತ್ತವೆ. ಎಲ್ಲಾ ಟ್ರಿಪ್ ನೋಡಲು ಖಾಲಿ ಬಿಡಿ.',
    'Operating Districts / Routes': 'ಕಾರ್ಯನಿರ್ವಹಿಸುವ ಜಿಲ್ಲೆಗಳು / ಮಾರ್ಗಗಳು',
    'Separate multiple districts with commas':
        'ಹಲವು ಜಿಲ್ಲೆಗಳನ್ನು ಕಾಮಾದಿಂದ ಬೇರ್ಪಡಿಸಿ',
    'Quick add': 'ತ್ವರಿತವಾಗಿ ಸೇರಿಸಿ',
    'SAVE ROUTES': 'ಮಾರ್ಗಗಳನ್ನು ಉಳಿಸಿ',
    'Where your trip earnings are settled. Either bank or UPI is enough.':
        'ಟ್ರಿಪ್ ಗಳಿಕೆ ಜಮೆಯಾಗುವ ಖಾತೆ. ಬ್ಯಾಂಕ್ ಅಥವಾ UPI ಒಂದಿದ್ದರೆ ಸಾಕು.',

    // Payment QR Dialog & Scanner App
    'Mandi Payment QR': 'ಮಂಡಿ ಪಾವತಿ QR',
    'Pool Payment QR': 'ಪೂಲ್ ಪಾವತಿ QR',
    'Payment QR': 'ಪಾವತಿ QR',
    'Payment Done!': 'ಪಾವತಿ ಮುಗಿದಿದೆ!',
    'Fetching live mandi rate & generating QR…':
        'ಲೈವ್ ಮಂಡಿ ದರ ಪಡೆದು QR ರಚಿಸಲಾಗುತ್ತಿದೆ…',
    'TOTAL POOL AMOUNT TO PAY': 'ಪಾವತಿಸಬೇಕಾದ ಒಟ್ಟು ಪೂಲ್ ಮೊತ್ತ',
    'TOTAL CROP AMOUNT TO PAY': 'ಪಾವತಿಸಬೇಕಾದ ಒಟ್ಟು ಬೆಳೆ ಮೊತ್ತ',
    'QR payload copied for demo testing.':
        'ಡೆಮೋ ಪರೀಕ್ಷೆಗಾಗಿ QR ಕೋಡ್ ನಕಲಿಸಲಾಗಿದೆ.',
    'Ask Mandi Owner to scan using KisanRider Scanner. Auto-checking every 3s…':
        'ಮಂಡಿ ಮಾಲೀಕರು KisanRider ಸ್ಕ್ಯಾನರ್‌ನಿಂದ ಸ್ಕ್ಯಾನ್ ಮಾಡಲಿ. ಪ್ರತಿ 3 ಸೆಕೆಂಡ್‌ಗೆ ಪರಿಶೀಲಿಸುತ್ತಿದೆ…',
    'Payment Received!': 'ಪಾವತಿ ಸ್ವೀಕರಿಸಲಾಗಿದೆ!',
    'PAYMENT AUTO-SPLIT SUMMARY': 'ಪಾವತಿ ಸ್ವಯಂ-ವಿಭಜನೆ ಸಾರಾಂಶ',
    'AUTO-SPLIT PREVIEW': 'ಸ್ವಯಂ-ವಿಭಜನೆ ಮುನ್ನೋಟ',
    'Farmers Net ({count} Farmers)': 'ರೈತರ ನಿವ್ವಳ ಮೊತ್ತ ({count} ರೈತರು)',
    'Farmer Net Payout': 'ರೈತರ ನಿವ್ವಳ ಪಾವತಿ',
    'Could not generate QR (HTTP {code}).': 'QR ರಚಿಸಲು ಸಾಧ್ಯವಾಗಲಿಲ್ಲ (HTTP {code}).',
    'Invalid KisanRider QR (HTTP {code}).': 'ಅಮಾನ್ಯ ಕಿಸಾನ್‌ರೈಡರ್ QR (HTTP {code}).',
    'Could not reach backend ({url}): {err}':
        'ಬ್ಯಾಕೆಂಡ್ ಸಂಪರ್ಕಿಸಲು ಸಾಧ್ಯವಾಗಲಿಲ್ಲ ({url}): {err}',
    'Payment failed (HTTP {code}).': 'ಪಾವತಿ ವಿಫಲವಾಗಿದೆ (HTTP {code}).',
    'Camera unavailable ({code}).\nUse "Enter QR Code" below for demo testing.':
        'ಕ್ಯಾಮೆರಾ ಲಭ್ಯವಿಲ್ಲ ({code}).\nಡೆಮೋ ಪರೀಕ್ಷೆಗಾಗಿ ಕೆಳಗಿನ "QR ಕೋಡ್ ನಮೂದಿಸಿ" ಬಳಸಿ.',
    'Mandi: {name}': 'ಮಂಡಿ: {name}',
    'Live Mandi API': 'ಲೈವ್ ಮಂಡಿ API',
    'Live Mandi Rate': 'ಲೈವ್ ಮಂಡಿ ದರ',
    'Standard Rate': 'ಪ್ರಮಾಣಿತ ದರ',
    'Enter Payment QR Code': 'ಪಾವತಿ QR ಕೋಡ್ ನಮೂದಿಸಿ',
    'QR Payload': 'QR ಡೇಟಾ',
    'Inspect': 'ಪರಿಶೀಲಿಸಿ',
    'Backend Server URL': 'ಬ್ಯಾಕೆಂಡ್ ಸರ್ವರ್ URL',
    'Toggle Flash': 'ಫ್ಲ್ಯಾಶ್ ಆನ್/ಆಫ್',
    'Flip Camera': 'ಕ್ಯಾಮೆರಾ ಬದಲಿಸಿ',
    'Server Settings': 'ಸರ್ವರ್ ಸೆಟ್ಟಿಂಗ್‌ಗಳು',
    'Reading KisanRider Payment QR…': 'ಕಿಸಾನ್‌ರೈಡರ್ ಪಾವತಿ QR ಓದುತ್ತಿದೆ…',
    "Scan Rider's KisanRider QR Code to Pay":
        'ಪಾವತಿಸಲು ರೈಡರ್‌ನ ಕಿಸಾನ್‌ರೈಡರ್ QR ಕೋಡ್ ಸ್ಕ್ಯಾನ್ ಮಾಡಿ',
    'Amount and auto-split (Rider Fare, Platform Fee & Farmer Payout) load automatically.':
        'ಮೊತ್ತ ಮತ್ತು ಸ್ವಯಂ-ವಿಭಜನೆ (ರೈಡರ್ ಬಾಡಿಗೆ, ಪ್ಲಾಟ್‌ಫಾರ್ಮ್ ಶುಲ್ಕ ಮತ್ತು ರೈತ ಪಾವತಿ) ತಾನಾಗಿಯೇ ಲೋಡ್ ಆಗುತ್ತದೆ.',
    'Enter / Paste QR Code Manually': 'QR ಕೋಡ್ ಕೈಯಾರೆ ನಮೂದಿಸಿ / ಅಂಟಿಸಿ',
    'Enter a numeric PIN (4 to 8 digits only).':
        'ಕೇವಲ ಅಂಕಿಗಳ PIN ನಮೂದಿಸಿ (4 ರಿಂದ 8 ಅಂಕಿಗಳು ಮಾತ್ರ).',
    'Confirm Mandi Payment': 'ಮಂಡಿ ಪಾವತಿ ದೃಢೀಕರಿಸಿ',
    'POOLED DELIVERY · {count} FARMERS': 'ಪೂಲ್ ವಿತರಣೆ · {count} ರೈತರು',
    'INDIVIDUAL DELIVERY': 'ವೈಯಕ್ತಿಕ ವಿತರಣೆ',
    'PAYABLE AMOUNT': 'ಪಾವತಿಸಬೇಕಾದ ಮೊತ್ತ',
    'AUTOMATIC PAYMENT SPLIT': 'ಸ್ವಯಂಚಾಲಿತ ಪಾವತಿ ವಿಭಜನೆ',
    'Rider Account ({name})': 'ರೈಡರ್ ಖಾತೆ ({name})',
    'Farmers Net Total': 'ರೈತರ ಒಟ್ಟು ನಿವ್ವಳ ಮೊತ್ತ',
    'Farmer Account ({name})': 'ರೈತರ ಖಾತೆ ({name})',
    'Enter Demo Payment PIN': 'ಡೆಮೋ ಪಾವತಿ PIN ನಮೂದಿಸಿ',
    'Any 4 to 8 numeric digits accepted for demo authorization.':
        'ಡೆಮೋ ಅನುಮೋದನೆಗಾಗಿ ಯಾವುದೇ 4 ರಿಂದ 8 ಅಂಕಿಗಳನ್ನು ನಮೂದಿಸಿ.',
    'Processing Payment…': 'ಪಾವತಿ ಪ್ರಕ್ರಿಯೆಯಲ್ಲಿದೆ…',
    'PAY {amount} NOW': 'ಈಗ {amount} ಪಾವತಿಸಿ',
    'Payment Receipt': 'ಪಾವತಿ ರಶೀದಿ',
    'Already Paid': 'ಈಗಾಗಲೇ ಪಾವತಿಸಲಾಗಿದೆ',
    'Payment Successful!': 'ಪಾವತಿ ಯಶಸ್ವಿಯಾಗಿದೆ!',
    'SETTLED SPLIT BREAKDOWN': 'ಇತ್ಯರ್ಥವಾದ ವಿಭಜನೆ ವಿವರ',
    'Rider Credited ({name})': 'ರೈಡರ್‌ಗೆ ಜಮೆ ({name})',
    'Farmer Net Credited': 'ರೈತರಿಗೆ ನಿವ್ವಳ ಜಮೆ',
    'Scan Next QR': 'ಮುಂದಿನ QR ಸ್ಕ್ಯಾನ್ ಮಾಡಿ',

    // Karnataka Districts (31)
    'Bagalkot': 'ಬಾಗಲಕೋಟೆ',
    'Bagalkote': 'ಬಾಗಲಕೋಟೆ',
    'Ballari': 'ಬಳ್ಳಾರಿ',
    'Ballari (Bellary)': 'ಬಳ್ಳಾರಿ',
    'Belagavi': 'ಬೆಳಗಾವಿ',
    'Belagavi (Belgaum)': 'ಬೆಳಗಾವಿ',
    'Bengaluru Rural': 'ಬೆಂಗಳೂರು ಗ್ರಾಮಾಂತರ',
    'Bengaluru Urban': 'ಬೆಂಗಳೂರು ನಗರ',
    'Bidar': 'ಬೀದರ್',
    'Chamarajanagar': 'ಚಾಮರಾಜನಗರ',
    'Chamarajanagara': 'ಚಾಮರಾಜನಗರ',
    'Chikkaballapura': 'ಚಿಕ್ಕಬಳ್ಳಾಪುರ',
    'Chikkamagaluru': 'ಚಿಕ್ಕಮಗಳೂರು',
    'Chitradurga': 'ಚಿತ್ರದುರ್ಗ',
    'Dakshina Kannada': 'ದಕ್ಷಿಣ ಕನ್ನಡ',
    'Davanagere': 'ದಾವಣಗೆರೆ',
    'Dharwad': 'ಧಾರವಾಡ',
    'Gadag': 'ಗದಗ',
    'Hassan': 'ಹಾಸನ',
    'Haveri': 'ಹಾವೇರಿ',
    'Kalaburagi': 'ಕಲಬುರಗಿ',
    'Kalaburagi (Gulbarga)': 'ಕಲಬುರಗಿ',
    'Kodagu': 'ಕೊಡಗು',
    'Kolar': 'ಕೋಲಾರ',
    'Koppal': 'ಕೊಪ್ಪಳ',
    'Mandya': 'ಮಂಡ್ಯ',
    'Mysuru': 'ಮೈಸೂರು',
    'Mysuru (Mysore)': 'ಮೈಸೂರು',
    'Raichur': 'ರಾಯಚೂರು',
    'Ramanagara': 'ರಾಮನಗರ',
    'Shivamogga': 'ಶಿವಮೊಗ್ಗ',
    'Shivamogga (Shimoga)': 'ಶಿವಮೊಗ್ಗ',
    'Tumakuru': 'ತುಮಕೂರು',
    'Tumakuru (Tumkur)': 'ತುಮಕೂರು',
    'Udupi': 'ಉಡುಪಿ',
    'Uttara Kannada': 'ಉತ್ತರ ಕನ್ನಡ',
    'Vijayapura': 'ವಿಜಯಪುರ',
    'Vijayapura (Bijapur)': 'ವಿಜಯಪುರ',
    'Yadgir': 'ಯಾದಗಿರಿ',
    'Vijayanagara': 'ವಿಜಯನಗರ',

    // Audit additions: common UI, units, errors & dynamic labels
    ' (if using Camera, try Gallery instead — browsers often block camera access on non-HTTPS origins or desktops without a webcam)':
        ' (ಕ್ಯಾಮೆರಾ ಬಳಸುತ್ತಿದ್ದರೆ, ಬದಲಾಗಿ ಗ್ಯಾಲರಿ ಪ್ರಯತ್ನಿಸಿ — HTTPS ಅಲ್ಲದ ಮೂಲಗಳು ಅಥವಾ ವೆಬ್‌ಕ್ಯಾಮ್ ಇಲ್ಲದ ಡೆಸ್ಕ್‌ಟಾಪ್‌ಗಳಲ್ಲಿ ಬ್ರೌಸರ್‌ಗಳು ಕ್ಯಾಮೆರಾ ಪ್ರವೇಶವನ್ನು ನಿರ್ಬಂಧಿಸುತ್ತವೆ)',
    'APMC': 'ಎಪಿಎಂಸಿ',
    'GPS': 'ಜಿಪಿಎಸ್',
    'ROUTE': 'ಮಾರ್ಗ',
    'SOON': 'ಶೀಘ್ರ',
    'at': 'ರಂದು',
    'estimated': 'ಅಂದಾಜು',
    'km': 'ಕಿ.ಮೀ',
    'mins': 'ನಿಮಿಷ',
    'e.g. Shop #14': 'ಉದಾ. ಅಂಗಡಿ #14',
    'Fallback ₹50': 'ಸಾಮಾನ್ಯ ₹50',
    'Mandi API': 'ಮಂಡಿ API',
    'Mandi API Rate': 'ಮಂಡಿ API ದರ',
    'Standard ₹50/kg': 'ಸಾಮಾನ್ಯ ₹50/ಕೆಜಿ',
    'Standard ₹50/kg Fallback': 'ಸಾಮಾನ್ಯ ₹50/ಕೆಜಿ ದರ',
    'Capacity Alert: Pool total ({total} kg) exceeds your registered vehicle payload capacity ({cap} kg). Acceptance disabled.':
        'ಸಾಮರ್ಥ್ಯ ಎಚ್ಚರಿಕೆ: ಪೂಲ್ ಒಟ್ಟು ತೂಕ ({total} ಕೆಜಿ) ನಿಮ್ಮ ನೋಂದಾಯಿತ ವಾಹನದ ಹೊರೆ ಸಾಮರ್ಥ್ಯ ({cap} ಕೆಜಿ) ಮೀರಿದೆ. ಸ್ವೀಕಾರ ನಿಷ್ಕ್ರಿಯಗೊಳಿಸಲಾಗಿದೆ.',
    'Capacity: {cur} / {max} kg': 'ಸಾಮರ್ಥ್ಯ: {cur} / {max} ಕೆಜಿ',
    'Coords: {lat}, {lng}': 'ನಿರ್ದೇಶಾಂಕಗಳು: {lat}, {lng}',
    'Could not fetch location: {err}': 'ಸ್ಥಳವನ್ನು ಪಡೆಯಲು ಸಾಧ್ಯವಾಗಲಿಲ್ಲ: {err}',
    'Could not load markets (HTTP {code}).':
        'ಮಾರುಕಟ್ಟೆಗಳನ್ನು ಲೋಡ್ ಮಾಡಲು ಸಾಧ್ಯವಾಗಲಿಲ್ಲ (HTTP {code}).',
    'Could not load markets.': 'ಮಾರುಕಟ್ಟೆಗಳನ್ನು ಲೋಡ್ ಮಾಡಲು ಸಾಧ್ಯವಾಗಲಿಲ್ಲ.',
    'Could not mark pool delivered (HTTP {code}).':
        'ಪೂಲ್ ತಲುಪಿಸಲಾಗಿದೆ ಎಂದು ಗುರುತಿಸಲು ಸಾಧ್ಯವಾಗಲಿಲ್ಲ (HTTP {code}).',
    'Could not mark trip delivered (HTTP {code}).':
        'ಟ್ರಿಪ್ ತಲುಪಿಸಲಾಗಿದೆ ಎಂದು ಗುರುತಿಸಲು ಸಾಧ್ಯವಾಗಲಿಲ್ಲ (HTTP {code}).',
    'Could not pick image: {err}': 'ಚಿತ್ರವನ್ನು ಆಯ್ಕೆ ಮಾಡಲು ಸಾಧ್ಯವಾಗಲಿಲ್ಲ: {err}',
    'Could not post request (HTTP {code}).':
        'ವಿನಂತಿಯನ್ನು ಪೋಸ್ಟ್ ಮಾಡಲು ಸಾಧ್ಯವಾಗಲಿಲ್ಲ (HTTP {code}).',
    'Could not update request (HTTP {code}).':
        'ವಿನಂತಿಯನ್ನು ನವೀಕರಿಸಲು ಸಾಧ್ಯವಾಗಲಿಲ್ಲ (HTTP {code}).',
    'Destination: {dropoff}': 'ತಲುಪುವ ಸ್ಥಳ: {dropoff}',
    'Expected Pickup: {time}': 'ನಿರೀಕ್ಷಿತ ಪಿಕಪ್: {time}',
    'Failed to cancel pool': 'ಪೂಲ್ ರದ್ದುಗೊಳಿಸಲು ವಿಫಲವಾಗಿದೆ',
    'Failed to create pool': 'ಪೂಲ್ ರಚಿಸಲು ವಿಫಲವಾಗಿದೆ',
    'Failed to create pool.': 'ಪೂಲ್ ರಚಿಸಲು ವಿಫಲವಾಗಿದೆ.',
    'Failed to create produce request.': 'ಬೆಳೆ ವಿನಂತಿಯನ್ನು ರಚಿಸಲು ವಿಫಲವಾಗಿದೆ.',
    'Failed to group pool': 'ಪೂಲ್ ಗುಂಪು ಮಾಡಲು ವಿಫಲವಾಗಿದೆ',
    'Failed to join pool': 'ಪೂಲ್ ಸೇರಲು ವಿಫಲವಾಗಿದೆ',
    'Failed to leave pool': 'ಪೂಲ್ ಬಿಡಲು ವಿಫಲವಾಗಿದೆ',
    'Failed to load my pools': 'ನನ್ನ ಪೂಲ್‌ಗಳನ್ನು ಲೋಡ್ ಮಾಡಲು ವಿಫಲವಾಗಿದೆ',
    'Failed to load nearby farmers': 'ಹತ್ತಿರದ ರೈತರನ್ನು ಲೋಡ್ ಮಾಡಲು ವಿಫಲವಾಗಿದೆ',
    'Failed to load pool details': 'ಪೂಲ್ ವಿವರಗಳನ್ನು ಲೋಡ್ ಮಾಡಲು ವಿಫಲವಾಗಿದೆ',
    'Failed to load pools': 'ಪೂಲ್‌ಗಳನ್ನು ಲೋಡ್ ಮಾಡಲು ವಿಫಲವಾಗಿದೆ',
    'Failed to load route optimization (HTTP {code}).':
        'ಮಾರ್ಗ ಆಪ್ಟಿಮೈಸೇಶನ್ ಲೋಡ್ ಮಾಡಲು ವಿಫಲವಾಗಿದೆ (HTTP {code}).',
    'Failed to load saved addresses (HTTP {code}).':
        'ಉಳಿಸಿದ ವಿಳಾಸಗಳನ್ನು ಲೋಡ್ ಮಾಡಲು ವಿಫಲವಾಗಿದೆ (HTTP {code}).',
    'Failed to load saved addresses.': 'ಉಳಿಸಿದ ವಿಳಾಸಗಳನ್ನು ಲೋಡ್ ಮಾಡಲು ವಿಫಲವಾಗಿದೆ.',
    'Failed to load trips (HTTP {code}).':
        'ಟ್ರಿಪ್‌ಗಳನ್ನು ಲೋಡ್ ಮಾಡಲು ವಿಫಲವಾಗಿದೆ (HTTP {code}).',
    'No markets found for "{district}".':
        '"{district}" ಜಿಲ್ಲೆಗೆ ಯಾವುದೇ ಮಾರುಕಟ್ಟೆಗಳು ಕಂಡುಬಂದಿಲ್ಲ.',
    'No phone number available': 'ಫೋನ್ ಸಂಖ್ಯೆ ಲಭ್ಯವಿಲ್ಲ',
    'No saved places yet. Use Manual Entry to bookmark one.':
        'ಇನ್ನೂ ಯಾವುದೇ ಉಳಿಸಿದ ಸ್ಥಳಗಳಿಲ್ಲ. ಒಂದನ್ನು ಬುಕ್‌ಮಾರ್ಕ್ ಮಾಡಲು ಕೈಯಾರೆ ನಮೂದಿಸಿ ಬಳಸಿ.',
    'Pickup Window Ends must be later than Pickup Window Starts.':
        'ಪಿಕಪ್ ಸಮಯದ ಅಂತ್ಯವು ಪ್ರಾರಂಭದ ಸಮಯಕ್ಕಿಂತ ನಂತರದಾಗಿರಬೇಕು.',
    'Pickup Window Starts cannot be in the past.':
        'ಪಿಕಪ್ ಸಮಯದ ಪ್ರಾರಂಭವು ಹಿಂದಿನ ಸಮಯವಾಗಿರಲು ಸಾಧ್ಯವಿಲ್ಲ.',
    'Pickup Window: {window}': 'ಪಿಕಪ್ ಸಮಯ: {window}',
    'Pickup: {addr}': 'ಪಿಕಪ್: {addr}',
    'Please pick one of your saved places.':
        'ದಯವಿಟ್ಟು ನಿಮ್ಮ ಉಳಿಸಿದ ಸ್ಥಳಗಳಲ್ಲಿ ಒಂದನ್ನು ಆಯ್ಕೆಮಾಡಿ.',
    'Please select both Pickup Window Starts and Ends.':
        'ದಯವಿಟ್ಟು ಪಿಕಪ್ ಪ್ರಾರಂಭ ಮತ್ತು ಅಂತ್ಯದ ಸಮಯ ಎರಡನ್ನೂ ಆಯ್ಕೆಮಾಡಿ.',
    'Pool marked as delivered!': 'ಪೂಲ್ ತಲುಪಿಸಲಾಗಿದೆ ಎಂದು ಗುರುತಿಸಲಾಗಿದೆ!',
    'Rate: ₹{rate}/kg ({source})': 'ದರ: ₹{rate}/ಕೆಜಿ ({source})',
    'Rider Fare ({name})': 'ಸವಾರರ ಬಾಡಿಗೆ ({name})',
    'Server did not return a valid photo URL.':
        'ಸರ್ವರ್ ಮಾನ್ಯವಾದ ಫೋಟೋ URL ಹಿಂತಿರುಗಿಸಲಿಲ್ಲ.',
    'Server error (HTTP {code}). Check backend logs.':
        'ಸರ್ವರ್ ದೋಷ (HTTP {code}). ಬ್ಯಾಕ್‌ಎಂಡ್ ಲಾಗ್‌ಗಳನ್ನು ಪರಿಶೀಲಿಸಿ.',
    'Trip must be PICKED_UP before completing (current: {status}).':
        'ಪೂರ್ಣಗೊಳಿಸುವ ಮೊದಲು ಟ್ರಿಪ್ ಪಿಕಪ್ ಆಗಿರಬೇಕು (ಪ್ರಸ್ತುತ: {status}).',
    'Window: {window}': 'ಸಮಯ: {window}',
    '{count} matches within 10 km': '10 ಕಿ.ಮೀ ಒಳಗೆ {count} ಹೊಂದಾಣಿಕೆಗಳು',
    '{crop} Pool': '{crop} ಪೂಲ್',
    '{dist} km away': '{dist} ಕಿ.ಮೀ ದೂರದಲ್ಲಿ',
    '{weight} kg / {count} farmers': '{weight} ಕೆಜಿ / {count} ರೈತರು',
    '₹{fare} each': 'ತಲಾ ₹{fare}',
    'Accept Freight Pool': 'ಫ್ರೈಟ್ ಪೂಲ್ ಒಪ್ಪಿಕೊಳ್ಳಿ',
    'Accepting Pool…': 'ಪೂಲ್ ಒಪ್ಪಿಕೊಳ್ಳಲಾಗುತ್ತಿದೆ…',
    'Accept Pool': 'ಪೂಲ್ ಒಪ್ಪಿಕೊಳ್ಳಿ',
    'Accept Request': 'ವಿನಂತಿ ಒಪ್ಪಿಕೊಳ್ಳಿ',
    'Accepting…': 'ಒಪ್ಪಿಕೊಳ್ಳಲಾಗುತ್ತಿದೆ…',

    // Payment method & mode chips
    'QR Payment at Mandi': 'ಮಂಡಿಯಲ್ಲಿ QR ಪಾವತಿ',
    'Cash in Hand': 'ನಗದು ಪಾವತಿ',
    'Cash In Hand': 'ನಗದು ಪಾವತಿ',
    'Wallet Credited': 'ವಾಲೆಟ್‌ಗೆ ಜಮೆ',
    'Cash Collected': 'ನಗದು ಸಂಗ್ರಹಿಸಲಾಗಿದೆ',
    'UPI': 'ಯುಪಿಐ (UPI)',
    'QR': 'ಕ್ಯೂಆರ್ (QR)',
    'Cash': 'ನಗದು',
    'CASH': 'ನಗದು',
    'Card': 'ಕಾರ್ಡ್',
    'CARD': 'ಕಾರ್ಡ್',
    'Online': 'ಆನ್‌ಲೈನ್',
    'ONLINE': 'ಆನ್‌ಲೈನ್',
    'COD': 'ನಗದು (COD)',
  };
}

extension TrBuildContext on BuildContext {
  /// Subscribes cleanly to [LanguageProvider] when present above in the tree
  /// (falling back to [AppStrings.currentLanguage] in standalone/test widgets).
  String tr(String text, {Map<String, String>? args}) {
    String lang = AppStrings.currentLanguage;
    try {
      lang = Provider.of<LanguageProvider>(this).languageCode;
    } catch (_) {}
    return AppStrings.tr(text, args: args, lang: lang);
  }

  String trStatus(String rawStatus) {
    String lang = AppStrings.currentLanguage;
    try {
      lang = Provider.of<LanguageProvider>(this).languageCode;
    } catch (_) {}
    return AppStrings.trStatus(rawStatus, lang: lang);
  }

  /// Safe to call inside async gaps, dialog callbacks, and initState without
  /// registering a Provider listener dependency.
  String trAsync(String text, {Map<String, String>? args}) {
    return AppStrings.tr(text, args: args, lang: AppStrings.currentLanguage);
  }
}
