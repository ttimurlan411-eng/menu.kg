import 'package:supabase_flutter/supabase_flutter.dart';

/// Converts expected menu item mutation failures into safe UI messages.
String menuItemMutationErrorMessage(Object error) {
  if (error is ArgumentError) {
    return 'Check the product details and try again.';
  }

  if (error is PostgrestException) {
    if (error.code == '22023') {
      return 'Check the product details and try again.';
    }
    if (error.code == '28000') {
      return 'Your session has ended. Please sign in again.';
    }
    if (error.code == '23514') {
      return 'Enter a price of 0 or more.';
    }
    if (error.code == '23503') {
      return 'Choose a category that still exists.';
    }

    final message = error.message.toLowerCase();
    if (message.contains('authentication')) {
      return 'Your session has ended. Please sign in again.';
    }
    if (message.contains('violates check constraint')) {
      return 'Enter a price of 0 or more.';
    }
    if (message.contains('foreign key')) {
      return 'Choose a category that still exists.';
    }
  }

  return 'We could not save this product. Please try again.';
}

/// Converts menu item deletion failures into safe UI messages.
String menuItemDeleteErrorMessage(Object error) {
  if (error is PostgrestException) {
    if (error.code == '28000') {
      return 'Your session has ended. Please sign in again.';
    }

    final message = error.message.toLowerCase();
    if (message.contains('authentication')) {
      return 'Your session has ended. Please sign in again.';
    }
  }

  return 'We could not delete this product. Please try again.';
}