import 'dart:convert';

import 'package:menukg_flutter/features/customer/reservations/data/models/reservation_model.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/models/staff_reservation_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'staff_order_test_data.dart';

/// When the reservation row was created, as the database sends it.
const String reservationCreatedAt = '2026-10-01T17:02:39.504534+00:00';

/// When the reservation row last changed, as the database sends it.
const String reservationUpdatedAt = '2026-10-02T09:15:00.000000+00:00';

const String reservationId = '8b8a7fe9-f457-494c-9f0a-e8f40ae9f136';
const String reservationTableId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';

/// Builds one entry of the `staff_list_reservations` payload.
///
/// Exactly the keys the database function sends: the ids a staff screen works
/// with, the booking itself and when the row last changed. There is no access
/// token in it, and none is built here, because the database sends none.
Map<String, dynamic> buildStaffReservationJson({
  String id = reservationId,
  String restaurantId = restaurantA,
  String branchId = centerBranch,
  String? tableId = reservationTableId,
  String reservedDate = '2026-10-05',
  String reservedTime = '19:00:00',
  String guestName = 'Askar',
  int guestCount = 2,
  String status = 'CONFIRMED',
  String createdAt = reservationCreatedAt,
  String updatedAt = reservationUpdatedAt,
}) {
  return {
    'id': id,
    'restaurant_id': restaurantId,
    'branch_id': branchId,
    'table_id': tableId,
    'reserved_date': reservedDate,
    'reserved_time': reservedTime,
    'guest_name': guestName,
    'guest_count': guestCount,
    'status': status,
    'created_at': createdAt,
    'updated_at': updatedAt,
  };
}

/// Builds the whole `staff_list_reservations` payload: the wrapper the database
/// sends around the reservations, with the scope it answered for echoed back.
///
/// The reservations are [Object] rather than [Map] so a test can put something
/// that is not a reservation in the list, which is the shape a caller has to
/// survive.
Map<String, dynamic> buildStaffReservationsJson({
  String restaurantId = restaurantA,
  String? branchId,
  String? date,
  List<Object?>? reservations,
}) {
  return {
    'restaurant_id': restaurantId,
    'branch_id': branchId,
    'date': date,
    'reservations': reservations ?? [buildStaffReservationJson()],
  };
}

/// Builds the whole `staff_set_reservation_status` payload: only what changed.
Map<String, dynamic> buildStaffReservationStatusUpdateJson({
  String id = reservationId,
  String status = 'CANCELLED',
  String updatedAt = reservationUpdatedAt,
}) {
  return {'id': id, 'status': status, 'updated_at': updatedAt};
}

/// A reservation as a staff screen would hold one, built without going through
/// json, for widget tests.
///
/// Only the fields a test cares about are named, so a test can say what it is
/// about and nothing more.
StaffReservationModel buildStaffReservationModel({
  String id = reservationId,
  String restaurantId = restaurantA,
  String branchId = centerBranch,
  String? tableId = reservationTableId,
  DateTime? reservedDate,
  ({int hour, int minute}) reservedTime = (hour: 19, minute: 0),
  String guestName = 'Askar',
  int guestCount = 2,
  ReservationStatus status = ReservationStatus.confirmed,
  DateTime? createdAt,
  DateTime? updatedAt,
}) {
  return StaffReservationModel(
    id: id,
    restaurantId: restaurantId,
    branchId: branchId,
    tableId: tableId,
    reservedDate: reservedDate ?? DateTime(2026, 10, 5),
    reservedTime: reservedTime,
    guestName: guestName,
    guestCount: guestCount,
    status: status,
    createdAt: createdAt ?? DateTime.parse(reservationCreatedAt),
    updatedAt: updatedAt ?? DateTime.parse(reservationUpdatedAt),
  );
}

/// Wraps a payload the way postgrest does for a json-returning function.
String encodeReservationRpcResult(Object? payload) => jsonEncode(payload);

/// Builds the `PostgrestException` postgrest throws for a failed rpc, so error
/// mapping can be tested against the real shape the app sees.
PostgrestException reservationPostgrestError(
  String code, {
  String message = '',
}) {
  return PostgrestException(message: message, code: code);
}
