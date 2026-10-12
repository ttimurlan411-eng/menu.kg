import 'package:supabase_flutter/supabase_flutter.dart';

/// Converts expected table mutation failures into safe UI messages.
String tableMutationErrorMessage(Object error) {
  if (error is ArgumentError) {
    return 'Check the table details and try again.';
  }

  if (error is PostgrestException) {
    if (error.code == '28000') {
      return 'Your session has ended. Please sign in again.';
    }
    // check constraints: capacity > 0 and the status allow list.
    if (error.code == '23514') {
      return 'Enter a capacity of at least 1 and a valid status.';
    }
    // foreign_key_violation: the branch belongs to another restaurant.
    if (error.code == '23503') {
      return 'That branch does not belong to your restaurant.';
    }
    if (error.code == '42501') {
      return 'You do not have permission to manage tables.';
    }

    final message = error.message.toLowerCase();
    if (message.contains('authentication')) {
      return 'Your session has ended. Please sign in again.';
    }
    if (message.contains('row-level security')) {
      return 'You do not have permission to manage tables.';
    }
    if (message.contains('foreign key')) {
      return 'That branch does not belong to your restaurant.';
    }
  }

  return 'We could not save this table. Please try again.';
}

/// Converts table deletion failures into safe UI messages.
String tableDeleteErrorMessage(Object error) {
  if (error is PostgrestException) {
    // Orders will reference tables once ordering is implemented.
    if (error.code == '23503') {
      return 'This table is used by other records and cannot be deleted yet.';
    }
    if (error.code == '28000') {
      return 'Your session has ended. Please sign in again.';
    }
    if (error.code == '42501') {
      return 'You do not have permission to manage tables.';
    }

    final message = error.message.toLowerCase();
    if (message.contains('foreign key') || message.contains('in use')) {
      return 'This table is used by other records and cannot be deleted yet.';
    }
    if (message.contains('authentication')) {
      return 'Your session has ended. Please sign in again.';
    }
  }

  return 'We could not delete this table. Please try again.';
}
