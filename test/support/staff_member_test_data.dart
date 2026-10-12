import 'package:menukg_flutter/features/restaurant_admin/data/models/staff_member_model.dart';

import 'staff_order_test_data.dart';

/// A member record id, shaped like a `restaurant_members.id`.
const String staffMemberId = '5c1f0d2a-3b4e-4a5f-8c9d-0e1f2a3b4c5d';

/// A second member record id, for lists with more than one member.
const String managedMemberId = '6d2e1f3b-4c5f-4b6a-9d0e-1f2a3b4c5d6e';

/// The profile id of the second member. The signed-in owner is [staffUserId].
const String managedMemberUserId = 'e0000000-0000-4000-8000-000000000002';

/// Builds one entry of the `staff_list_restaurant_members` payload.
///
/// Exactly the keys the database function sends: the member record, the profile
/// behind it, the display name (or null) and the stored role and active flag. There
/// is no email, phone, avatar or token in it, and none is built here, because the
/// database sends none.
Map<String, dynamic> buildStaffMemberJson({
  String id = staffMemberId,
  String userId = staffUserId,
  String? displayName = 'Aigerim Owner',
  String role = 'OWNER',
  bool isActive = true,
}) {
  return {
    'id': id,
    'user_id': userId,
    'display_name': displayName,
    'role': role,
    'is_active': isActive,
  };
}

/// Builds the whole `staff_list_restaurant_members` payload: the wrapper the
/// database sends around the members, with the restaurant it answered for.
///
/// The members are [Object] rather than [Map] so a test can put something that is
/// not a member in the list, which is the shape a caller has to survive.
Map<String, dynamic> buildStaffMembersJson({
  String restaurantId = restaurantA,
  List<Object?>? members,
}) {
  return {
    'restaurant_id': restaurantId,
    'members': members ?? [buildStaffMemberJson()],
  };
}

/// A staff member as a screen would hold one, built without going through json, for
/// widget tests.
StaffMemberModel buildStaffMemberModel({
  String id = staffMemberId,
  String userId = staffUserId,
  String? displayName = 'Aigerim Owner',
  String role = 'OWNER',
  bool isActive = true,
}) {
  return StaffMemberModel(
    id: id,
    userId: userId,
    displayName: displayName,
    role: role,
    isActive: isActive,
  );
}
