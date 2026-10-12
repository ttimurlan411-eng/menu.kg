import 'package:supabase_flutter/supabase_flutter.dart';

/// Converts expected category mutation failures into safe UI messages.
String categoryMutationErrorMessage(Object error) {
  if (error is ArgumentError) {
    return 'Check the category details and try again.';
  }

  if (error is PostgrestException) {
    if (error.code == '22023') {
      return 'Check the category details and try again.';
    }
    if (error.code == '28000') {
      return 'Your session has ended. Please sign in again.';
    }
    if (error.code == '23514') {
      return 'Enter a sort order of 0 or more.';
    }

    final message = error.message.toLowerCase();
    if (message.contains('authentication')) {
      return 'Your session has ended. Please sign in again.';
    }
    if (message.contains('violates check constraint')) {
      return 'Enter a sort order of 0 or more.';
    }
  }

  return 'We could not save this category. Please try again.';
}

/// Converts category deletion failures into safe UI messages.
String categoryDeleteErrorMessage(Object error) {
  if (error is PostgrestException) {
    // `menu_items.category_id` references categories with `on delete restrict`.
    if (error.code == '23503') {
      return 'This category is used by menu items and cannot be deleted yet.';
    }
    if (error.code == '28000') {
      return 'Your session has ended. Please sign in again.';
    }

    final message = error.message.toLowerCase();
    if (message.contains('foreign key') || message.contains('in use')) {
      return 'This category is used by menu items and cannot be deleted yet.';
    }
    if (message.contains('authentication')) {
      return 'Your session has ended. Please sign in again.';
    }
  }

  return 'We could not delete this category. Please try again.';
}