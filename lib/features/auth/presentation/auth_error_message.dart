import 'package:supabase_flutter/supabase_flutter.dart';

/// Converts expected authentication failures into messages safe to show in UI.
String authErrorMessage(Object error, {required bool isRegistration}) {
  if (error is AuthException) {
    switch (error.code) {
      case 'invalid_credentials':
        return 'Incorrect email or password.';
      case 'email_not_confirmed':
        return 'Please confirm your email address before signing in.';
      case 'user_already_exists':
        return 'An account already exists for this email address.';
      case 'weak_password':
        return 'Choose a stronger password and try again.';
      case 'over_email_send_rate_limit':
      case 'over_request_rate_limit':
        return 'Too many attempts. Please wait a moment and try again.';
    }

    final message = error.message.toLowerCase();
    if (message.contains('invalid login credentials')) {
      return 'Incorrect email or password.';
    }
    if (message.contains('email not confirmed')) {
      return 'Please confirm your email address before signing in.';
    }
    if (message.contains('already registered')) {
      return 'An account already exists for this email address.';
    }
    if (message.contains('password')) {
      return 'Choose a stronger password and try again.';
    }
    if (message.contains('rate limit') || message.contains('too many')) {
      return 'Too many attempts. Please wait a moment and try again.';
    }
  }

  return isRegistration
      ? 'We could not create your account. Please try again.'
      : 'We could not sign you in. Please try again.';
}
