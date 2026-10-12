import 'dart:convert';

import 'package:menukg_flutter/features/customer/menu/data/models/public_menu_model.dart';

/// Whether a reservation is still expected or has been called off.
///
/// The database constrains `status` to exactly these two values. An unknown
/// value is a [FormatException] rather than a silent fallback, so a payload this
/// client does not understand can never be shown to a guest as confirmed.
enum ReservationStatus {
  confirmed('CONFIRMED', 'Confirmed'),
  cancelled('CANCELLED', 'Cancelled');

  const ReservationStatus(this.databaseValue, this.displayLabel);

  /// The value stored in the `status` column.
  final String databaseValue;

  /// The wording shown to a member of staff, for example `Confirmed`.
  ///
  /// Kept beside [databaseValue] for the same reason the order lifecycle keeps
  /// its label beside its stored value: one lifecycle has one set of names, so a
  /// staff screen and a guest screen cannot be shown two different words for one
  /// state. Each label describes only what the database reports.
  final String displayLabel;

  static ReservationStatus fromDatabase(String value) {
    for (final status in values) {
      if (status.databaseValue == value) {
        return status;
      }
    }
    throw FormatException('Unknown reservation status: $value');
  }
}

/// One customer table reservation, as the guest may see it.
///
/// The payload is built by the `guest_reservations` and
/// `create_table_reservation` database functions, which send display labels
/// only. No restaurant, branch or table id ever reaches this model: [id] is the
/// guest's own reservation id, used to cancel, and the restaurant, branch and
/// table are names.
class ReservationModel {
  const ReservationModel({
    required this.id,
    required this.restaurantName,
    required this.branchName,
    required this.table,
    required this.reservedDate,
    required this.reservedTime,
    required this.guestName,
    required this.guestCount,
    required this.status,
    required this.createdAt,
  });

  /// Id of this reservation, used only to cancel it.
  final String id;

  final String restaurantName;
  final String branchName;

  /// The reserved table, as a display label.
  final PublicTableInfo table;

  /// The reserved day, without a time of day.
  final DateTime reservedDate;

  /// The reserved time of day, as an hour and minute.
  final ({int hour, int minute}) reservedTime;

  final String guestName;
  final int guestCount;
  final ReservationStatus status;
  final DateTime createdAt;

  bool get isCancelled => status == ReservationStatus.cancelled;

  /// One line describing when the table is booked, for example
  /// `Sat, 3 Oct 2026 · 19:00`.
  String get whenLabel =>
      '${formatReservationDay(reservedDate)} · '
      '${formatReservationClock(hour: reservedTime.hour, minute: reservedTime.minute)}';

  /// One line describing the party, for example `Askar · 2 guests`.
  String get partyLabel =>
      guestCount == 1 ? '$guestName · 1 guest' : '$guestName · $guestCount guests';

  factory ReservationModel.fromJson(Map<String, dynamic> json) {
    return ReservationModel(
      id: json['id'] as String,
      restaurantName: json['restaurant_name'] as String,
      branchName: json['branch_name'] as String,
      table: PublicTableInfo.fromJson(json['table'] as Map<String, dynamic>),
      reservedDate: _parseDate(json['reserved_date'] as String),
      reservedTime: _parseTime(json['reserved_time'] as String),
      guestName: json['guest_name'] as String,
      guestCount: (json['guest_count'] as num).toInt(),
      status: ReservationStatus.fromDatabase(json['status'] as String),
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  static DateTime _parseDate(String value) {
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

  static ({int hour, int minute}) _parseTime(String value) {
    // '19:00' or '19:00:00' from Postgres.
    final parts = value.split(':');
    if (parts.length < 2) {
      throw FormatException('Unknown reservation time: $value');
    }
    return (hour: int.parse(parts[0]), minute: int.parse(parts[1]));
  }
}

/// A newly created reservation together with the access token that proves it
/// belongs to this guest.
///
/// The token is the guest's only credential, so it is returned exactly once, by
/// the call that created the reservation, and afterwards the guest keeps it on
/// their own device.
class CreatedReservationModel {
  const CreatedReservationModel({
    required this.accessToken,
    required this.reservation,
  });

  final String accessToken;
  final ReservationModel reservation;

  factory CreatedReservationModel.fromJson(Map<String, dynamic> json) {
    return CreatedReservationModel(
      accessToken: json['access_token'] as String,
      reservation: ReservationModel.fromJson(
        json['reservation'] as Map<String, dynamic>,
      ),
    );
  }
}

/// Decodes an `rpc` response that may arrive as a decoded value or as a string.
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

/// Parses the `create_table_reservation` response.
///
/// Returns `null` when the database resolved nothing, which is how an unknown,
/// deleted or inactive QR code is reported, or when the payload is not a
/// reservation. It never invents a token.
CreatedReservationModel? tryParseCreatedReservation(Object? response) {
  final decoded = _decodeResponse(response);
  if (decoded is! Map<String, dynamic>) {
    return null;
  }
  final accessToken = decoded['access_token'];
  final reservation = decoded['reservation'];
  if (accessToken is! String ||
      accessToken.isEmpty ||
      reservation is! Map<String, dynamic>) {
    return null;
  }
  return CreatedReservationModel.fromJson(decoded);
}

/// Parses the `guest_reservations` response.
///
/// Returns an empty list when the guest token is unknown, because the database
/// reports an unknown token as an empty list rather than an error.
List<ReservationModel> tryParseReservations(Object? response) {
  final decoded = _decodeResponse(response);
  if (decoded is! Map<String, dynamic>) {
    return const [];
  }
  final raw = decoded['reservations'];
  if (raw is! List) {
    return const [];
  }
  return raw
      .whereType<Map<String, dynamic>>()
      .map(ReservationModel.fromJson)
      .toList();
}

const List<String> _weekdayNames = [
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
];

const List<String> _monthNames = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// Formats a reserved day, for example `Sat, 3 Oct 2026`.
String formatReservationDay(DateTime date) {
  final weekday = _weekdayNames[date.weekday - 1];
  final month = _monthNames[date.month - 1];
  return '$weekday, ${date.day} $month ${date.year}';
}

/// Formats a reserved time, for example `19:00`.
String formatReservationClock({required int hour, required int minute}) {
  final safeHour = hour.clamp(0, 23).toString().padLeft(2, '0');
  final safeMinute = minute.clamp(0, 59).toString().padLeft(2, '0');
  return '$safeHour:$safeMinute';
}
