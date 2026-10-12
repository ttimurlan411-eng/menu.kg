import 'package:supabase_flutter/supabase_flutter.dart';

/// Converts a failed staff member read into safe wording.
///
/// The database's refusals are fixed identifiers rather than prose, and each one is
/// mapped here. A raw postgrest error is never shown: it can name tables, columns,
/// constraints and internals of a function the caller is not meant to be able to
/// read, and nothing about this project is worth showing a restaurant member.
///
/// [error] may be anything a repository throws, not only a [PostgrestException]: a
/// screen that passes an arbitrary failure in gets the same safe fallback.
String staffMemberListErrorMessage(Object error) {
  if (error is PostgrestException) {
    if (error.code == '28000') {
      return 'Your session has ended. Please sign in again.';
    }
    // staff_member_access_denied: not an active owner or manager of that
    // restaurant, or a restaurant that does not exist. Both are one answer, and the
    // wording does not say which, because the database does not.
    if (error.code == '42501') {
      return 'You do not have permission to view staff members.';
    }

    final message = error.message.toLowerCase();
    if (message.contains('authentication')) {
      return 'Your session has ended. Please sign in again.';
    }
    if (message.contains('row-level security')) {
      return 'You do not have permission to view staff members.';
    }
  }

  return 'We could not load staff members. Please try again.';
}
