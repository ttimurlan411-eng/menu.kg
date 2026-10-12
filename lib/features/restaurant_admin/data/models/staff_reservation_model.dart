import 'dart:convert';

import 'package:menukg_flutter/features/customer/reservations/data/models/reservation_model.dart';

/// A reservation as the restaurant that took it sees it.
///
/// Built from the payload `staff_list_reservations` sends, which is the guest's
/// reservation plus what only staff need. Unlike the guest model this one names
/// ids: the restaurant, the branch and the table are what a staff screen works
/// with, and an active member can already read all three through the existing
/// policies. What it does not carry is anything belonging to the guest: there is
/// no access token and no `reservation_access` row anywhere in this model or in
/// the payload it is parsed from, so a staff screen holds no credential for
/// reading a reservation as the guest who made it.
///
/// Table display labels (number, name) are not in the payload either. `tables`
/// is readable by an active member, so a screen resolves them the way the rest
/// of the admin area does; this model therefore keeps the table id and no label.
///
/// The status is the shared [ReservationStatus], not a staff copy of it: this
/// app has one lifecycle and one set of names for it, and a staff screen and a
/// guest screen cannot be allowed to disagree about what
/// [ReservationStatus.cancelled] means.
class StaffReservationModel {
  const StaffReservationModel({
    required this.id,
    required this.restaurantId,
    required this.branchId,
    required this.reservedDate,
    required this.reservedTime,
    required this.guestName,
    required this.guestCount,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.tableId,
  });

  /// Id of this reservation, and the only thing `staff_set_reservation_status`
  /// needs to cancel it: the restaurant is read from the reservation itself, so
  /// a caller cannot name one.
  final String id;

  /// Restaurant that took the booking. Staff work one restaurant, so it is named.
  final String restaurantId;

  /// Branch the booking is for.
  final String branchId;

  /// The booked table, or `null` for a reservation without one.
  ///
  /// The column allows it and such a reservation is still listed rather than
  /// hidden, so it stays nullable here rather than being invented.
  final String? tableId;

  /// The reserved day, without a time of day.
  final DateTime reservedDate;

  /// The reserved time of day, as an hour and minute.
  final ({int hour, int minute}) reservedTime;

  final String guestName;
  final int guestCount;

  /// Where the reservation is in its life, as the database holds it.
  final ReservationStatus status;

  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isCancelled => status == ReservationStatus.cancelled;

  /// One line describing when the table is booked, for example
  /// `Sat, 3 Oct 2026 · 19:00`.
  String get whenLabel =>
      '${formatReservationDay(reservedDate)} · '
      '${formatReservationClock(hour: reservedTime.hour, minute: reservedTime.minute)}';

  /// One line describing the party, for example `Askar · 2 guests`.
  String get partyLabel =>
      guestCount == 1 ? '$guestName · 1 guest' : '$guestName · $guestCount guests';

  factory StaffReservationModel.fromJson(Map<String, dynamic> json) {
    return StaffReservationModel(
      id: json['id'] as String,
      restaurantId: json['restaurant_id'] as String,
      branchId: json['branch_id'] as String,
      tableId: json['table_id'] as String?,
      reservedDate: _parseReservedDate(json['reserved_date'] as String),
      reservedTime: _parseReservedTime(json['reserved_time'] as String),
      guestName: json['guest_name'] as String,
      guestCount: (json['guest_count'] as num).toInt(),
      status: ReservationStatus.fromDatabase(json['status'] as String),
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  static DateTime _parseReservedDate(String value) {
    // '2026-10-05' from Postgres, parsed as a local date with no time shift.
    final parts = value.split('-');
    if (parts.length != 3) {
      throw FormatException('Unknown reservation date: $value');
    }
    return DateTime(
      int.parse(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]),
    );
  }

  static ({int hour, int minute}) _parseReservedTime(String value) {
    // '19:00' or '19:00:00' from Postgres.
    final parts = value.split(':');
    if (parts.length < 2) {
      throw FormatException('Unknown reservation time: $value');
    }
    return (hour: int.parse(parts[0]), minute: int.parse(parts[1]));
  }

  /// The same reservation in a new state, for after a successful status change.
  ///
  /// Only the status and the moment it changed are replaced: the date, the time,
  /// the party and the table are what the reservation already holds, and
  /// re-reading the whole reservation after moving it would be a second request
  /// for information nothing changed. The only move this phase defines cannot
  /// rewrite any of it, so nothing kept here can disagree with the database.
  ///
  /// [updatedAt] defaults to now, which is what the database returned anyway;
  /// pass the database's own value when a screen wants the server's clock rather
  /// than the phone's.
  StaffReservationModel withStatus(
    ReservationStatus status, {
    DateTime? updatedAt,
  }) {
    return StaffReservationModel(
      id: id,
      restaurantId: restaurantId,
      branchId: branchId,
      tableId: tableId,
      reservedDate: reservedDate,
      reservedTime: reservedTime,
      guestName: guestName,
      guestCount: guestCount,
      status: status,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }
}

/// The answer to a successful status change: the reservation's id, the state it
/// is now in, and when the row changed.
///
/// Deliberately not a whole reservation. `staff_set_reservation_status` changes
/// nothing but the status, so returning anything else would invite a screen to
/// overwrite what it already has with a payload that says less about it than the
/// copy it holds.
class StaffReservationStatusUpdate {
  const StaffReservationStatusUpdate({
    required this.reservationId,
    required this.status,
    required this.updatedAt,
  });

  final String reservationId;
  final ReservationStatus status;
  final DateTime updatedAt;

  factory StaffReservationStatusUpdate.fromJson(Map<String, dynamic> json) {
    return StaffReservationStatusUpdate(
      reservationId: json['id'] as String,
      status: ReservationStatus.fromDatabase(json['status'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }
}

/// Decodes an `rpc` response that may arrive as a decoded value or as a string.
///
/// Shared shape with the other rpc parsers: postgrest sends a json-returning
/// function's answer as a string unless the client asks otherwise, and a client
/// that cannot read either shape has no reservation to show.
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

/// Parses the `staff_list_reservations` response for [restaurantId].
///
/// [restaurantId] is checked against the payload rather than only passed in, and
/// a payload that names another restaurant is reported as no reservations at
/// all. A response that arrived from somewhere else, or that a client attached
/// to the wrong request, therefore cannot be shown as another restaurant's
/// bookings; being strict here costs a reload and a wrong list costs a staff
/// member a guest's table.
///
/// A reservation this client cannot read is skipped rather than failing the
/// whole read, so one payload it does not understand cannot hide the bookings
/// around it. A reservation whose status it does not know is skipped by
/// [StaffReservationModel.fromJson] throwing, which is the same fail-safe the
/// order and guest reads apply: an unknown state is never shown as a state this
/// app understands.
List<StaffReservationModel> tryParseStaffReservations(
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
  final raw = decoded['reservations'];
  if (raw is! List) {
    return const [];
  }
  final reservations = <StaffReservationModel>[];
  for (final entry in raw) {
    if (entry is! Map<String, dynamic>) {
      continue;
    }
    try {
      reservations.add(StaffReservationModel.fromJson(entry));
    } on Object {
      continue;
    }
  }
  return reservations;
}

/// Parses the `staff_set_reservation_status` response.
///
/// Returns `null` for anything that is not a readable status change, so a
/// payload this client does not understand is reported as "nothing changed"
/// instead of a move the screen then claims to have made.
StaffReservationStatusUpdate? tryParseStaffReservationStatusUpdate(
  Object? response,
) {
  final decoded = _decodeResponse(response);
  if (decoded is! Map<String, dynamic>) {
    return null;
  }
  if (decoded['id'] is! String || decoded['updated_at'] is! String) {
    return null;
  }
  try {
    return StaffReservationStatusUpdate.fromJson(decoded);
  } on Object {
    return null;
  }
}
