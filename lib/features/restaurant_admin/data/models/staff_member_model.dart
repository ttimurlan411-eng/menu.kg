import 'dart:convert';

/// One member of a restaurant, as the management screen sees them.
///
/// Built from the payload `staff_list_restaurant_members` sends, which is the
/// minimum a staff list needs: the member record's id, the profile behind it, the
/// display name when the profile has one, the stored role and the stored active
/// flag. There is deliberately no email, no phone, no avatar and no token here —
/// the database function does not return them, so this model cannot carry them.
///
/// Both ids are kept on purpose. [id] is the `restaurant_members` row, which a later
/// activation/deactivation step names; [userId] is the profile id, so a screen can
/// key a person across a restaurant's records. Neither is a credential.
class StaffMemberModel {
  const StaffMemberModel({
    required this.id,
    required this.userId,
    required this.role,
    required this.isActive,
    this.displayName,
  });

  /// The `restaurant_members.id`: the member record's own id.
  final String id;

  /// The profile id behind the membership.
  final String userId;

  /// The profile's display name, or `null` when the profile holds none.
  ///
  /// Nullable rather than defaulted: the column allows it, the database sends
  /// null, and a screen must show that honestly instead of inventing a name.
  final String? displayName;

  /// The stored role: OWNER, MANAGER, WAITER, KITCHEN or CASHIER.
  final String role;

  /// Whether the membership is active.
  final bool isActive;

  /// Whether this member has a usable display name.
  bool get hasDisplayName =>
      displayName != null && displayName!.trim().isNotEmpty;

  /// The display name trimmed for display, or `null` when there is none.
  String? get trimmedDisplayName {
    final trimmed = displayName?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  factory StaffMemberModel.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final userId = json['user_id'];
    final role = json['role'];
    final isActive = json['is_active'];

    if (id is! String || userId is! String || role is! String) {
      throw const FormatException('Unknown staff member');
    }
    if (isActive is! bool) {
      throw const FormatException('Unknown staff member active flag');
    }

    final displayName = json['display_name'];

    return StaffMemberModel(
      id: id,
      userId: userId,
      role: role,
      isActive: isActive,
      displayName: displayName is String ? displayName : null,
    );
  }
}

/// Decodes an `rpc` response that may arrive as a decoded value or as a string.
///
/// Shared shape with the other rpc parsers: postgrest sends a json-returning
/// function's answer as a string unless the client asks otherwise, and a client
/// that cannot read either shape has no member list to show.
Object? _decodeResponse(Object? response) {
  Object? decoded = response;
  if (decoded is String) {
    if (decoded.trim().isEmpty) {
      return null;
    }
    try {
      decoded = jsonDecode(decoded);
    } on FormatException {
      return null;
    }
  }
  return decoded;
}

/// Parses the `staff_list_restaurant_members` response for [restaurantId].
///
/// [restaurantId] is checked against the payload rather than only passed in, and a
/// payload that names another restaurant is reported as no members at all. A
/// response that arrived from somewhere else, or that a client attached to the wrong
/// request, therefore cannot be shown as another restaurant's staff.
///
/// A member this client cannot read is skipped rather than failing the whole read,
/// so one entry it does not understand cannot hide the members around it. Because
/// the role is kept as the stored string, a role this app does not yet know is shown
/// rather than dropped: a staff member who is missing from the list is a worse
/// answer than one whose role label is unfamiliar.
List<StaffMemberModel> tryParseStaffMembers(
  Object? response, {
  required String restaurantId,
}) {
  final decoded = _decodeResponse(response);
  if (decoded is! Map<String, dynamic>) {
    return const [];
  }
  if (decoded['restaurant_id'] != restaurantId) {
    return const [];
  }
  final raw = decoded['members'];
  if (raw is! List) {
    return const [];
  }
  final members = <StaffMemberModel>[];
  for (final entry in raw) {
    if (entry is! Map<String, dynamic>) {
      continue;
    }
    try {
      members.add(StaffMemberModel.fromJson(entry));
    } on Object {
      continue;
    }
  }
  return members;
}
