import 'package:supabase_flutter/supabase_flutter.dart';

/// Converts public menu failures into safe, guest-facing messages.
///
/// Guests must never see database internals, constraint names, tokens or
/// service error text, so every branch maps to a fixed sentence.
String publicMenuErrorMessage(Object error) {
  if (error is PublicMenuUnavailableException) {
    return error.message;
  }

  if (error is PostgrestException) {
    // invalid_input_syntax: the token was not a uuid.
    if (error.code == '22P02') {
      return 'This QR code is not valid.';
    }
    // insufficient_privilege: the public function was revoked or misconfigured.
    if (error.code == '42501') {
      return 'This menu is not available right now.';
    }
    if (error.code == '28000') {
      return 'This menu is not available right now.';
    }

    final message = error.message.toLowerCase();
    if (message.contains('jwt') || message.contains('authorization')) {
      // The public function must never require a session.
      return 'This menu is not available right now.';
    }
    if (message.contains('syntax') || message.contains('uuid')) {
      return 'This QR code is not valid.';
    }
  }

  return 'We could not load this menu. Please try again.';
}

/// Shown when a QR code cannot be resolved to an available menu.
class PublicMenuUnavailableException implements Exception {
  const PublicMenuUnavailableException(this.message);

  final String message;

  @override
  String toString() => 'PublicMenuUnavailableException: $message';
}