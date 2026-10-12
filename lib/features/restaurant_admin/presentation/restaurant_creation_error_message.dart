import 'package:supabase_flutter/supabase_flutter.dart';

/// Converts expected restaurant bootstrap failures into safe UI messages.
String restaurantCreationErrorMessage(Object error) {
  if (error is ArgumentError) {
    return 'Check the restaurant details and try again.';
  }

  if (error is PostgrestException) {
    if (error.code == '23505') {
      return 'This slug is already in use. Please choose another one.';
    }
    if (error.code == '22023') {
      return 'Check the restaurant details and try again.';
    }
    if (error.code == '28000') {
      return 'Your session has ended. Please sign in again.';
    }

    final message = error.message.toLowerCase();
    if (message.contains('duplicate') || message.contains('unique')) {
      return 'This slug is already in use. Please choose another one.';
    }
    if (message.contains('authentication')) {
      return 'Your session has ended. Please sign in again.';
    }
  }

  return 'We could not create your restaurant. Please try again.';
}
