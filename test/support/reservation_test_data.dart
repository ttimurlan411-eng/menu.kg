import 'dart:convert';

import 'package:menukg_flutter/features/customer/reservations/data/models/reservation_model.dart';
import 'package:menukg_flutter/features/customer/reservations/data/repositories/reservation_repository.dart';
import 'package:menukg_flutter/features/customer/reservations/data/reservation_access_store.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A token shaped like the two uuids the database mints into one.
const String guestAccessToken =
    'e3694af2-1f16-4d2f-93e0-358162c56208e88eaa43-ee64-4a64-ba99-e9636181e723';

const String otherGuestAccessToken =
    'aa3694af-1f16-4d2f-93e0-358162c56208e88eaa43-ee64-4a64-ba99-e9636181e724';

/// Builds the json the `create_table_reservation` rpc returns.
Map<String, dynamic> buildCreatedReservationJson({
  String accessToken = guestAccessToken,
  String id = '8b8a7fe9-f457-494c-9f0a-e8f40ae9f136',
  String status = 'CONFIRMED',
}) {
  return {
    'access_token': accessToken,
    'reservation': buildReservationJson(id: id, status: status),
  };
}

/// Builds one entry of the `guest_reservations` rpc payload.
///
/// Exactly the columns the database function sends: display labels and the
/// guest's own reservation id, and no restaurant, branch or table id.
Map<String, dynamic> buildReservationJson({
  String id = '8b8a7fe9-f457-494c-9f0a-e8f40ae9f136',
  String restaurantName = 'Ala-Too',
  String branchName = 'Center',
  String tableNumber = '12',
  String? tableName = 'Window',
  String reservedDate = '2026-10-05',
  String reservedTime = '19:00:00',
  String guestName = 'Askar',
  int guestCount = 2,
  String status = 'CONFIRMED',
  String createdAt = '2026-10-01T17:02:39.504534+00:00',
}) {
  return {
    'id': id,
    'restaurant_name': restaurantName,
    'branch_name': branchName,
    'table': {'number': tableNumber, 'name': tableName},
    'reserved_date': reservedDate,
    'reserved_time': reservedTime,
    'guest_name': guestName,
    'guest_count': guestCount,
    'status': status,
    'created_at': createdAt,
  };
}

/// Wraps a payload the way postgrest does for a json-returning function.
String encodeRpcResult(Object? payload) => jsonEncode(payload);

/// A repository that answers from memory and records every call.
///
/// Used for page tests, where the interesting behaviour is what the page does
/// with a result, not the request the postgrest client would send.
class FakeReservationRepository extends ReservationRepository {
  FakeReservationRepository({
    this.created,
    this.reservations = const [],
    this.cancelled = true,
    this.createError,
    this.listError,
    this.cancelError,
  });

  /// Returned by [createReservation]; `null` models a token the database could
  /// not resolve, which is the same answer an unknown QR code gets.
  CreatedReservationModel? created;

  List<ReservationModel> reservations;
  bool cancelled;
  Object? createError;
  Object? listError;
  Object? cancelError;

  final List<Map<String, Object?>> createCalls = [];
  final List<String?> listCalls = [];
  final List<Map<String, String>> cancelCalls = [];

  @override
  Future<CreatedReservationModel?> createReservation({
    required String qrToken,
    required DateTime date,
    required int hour,
    required int minute,
    required String guestName,
    required int guestCount,
    String? accessToken,
  }) async {
    createCalls.add({
      'qrToken': qrToken,
      'date': date,
      'hour': hour,
      'minute': minute,
      'guestName': guestName,
      'guestCount': guestCount,
      'accessToken': accessToken,
    });
    if (createError != null) {
      throw createError!;
    }
    return created;
  }

  @override
  Future<List<ReservationModel>> getMyReservations(String? accessToken) async {
    listCalls.add(accessToken);
    if (listError != null) {
      throw listError!;
    }
    return reservations;
  }

  @override
  Future<bool> cancelReservation({
    required String accessToken,
    required String reservationId,
  }) async {
    cancelCalls.add({
      'accessToken': accessToken,
      'reservationId': reservationId,
    });
    if (cancelError != null) {
      throw cancelError!;
    }
    if (cancelled) {
      reservations = reservations
          .map(
            (reservation) => reservation.id == reservationId
                ? ReservationModel(
                    id: reservation.id,
                    restaurantName: reservation.restaurantName,
                    branchName: reservation.branchName,
                    table: reservation.table,
                    reservedDate: reservation.reservedDate,
                    reservedTime: reservation.reservedTime,
                    guestName: reservation.guestName,
                    guestCount: reservation.guestCount,
                    status: ReservationStatus.cancelled,
                    createdAt: reservation.createdAt,
                  )
                : reservation,
          )
          .toList();
    }
    return cancelled;
  }
}

/// An in-memory access store, so page tests never touch the platform channel.
class MemoryReservationAccessStore implements ReservationAccessStore {
  MemoryReservationAccessStore([this.token]);

  String? token;
  int reads = 0;
  int writes = 0;
  int clears = 0;

  @override
  Future<String?> readToken() async {
    reads++;
    return token;
  }

  @override
  Future<void> writeToken(String token) async {
    writes++;
    this.token = token;
  }

  @override
  Future<void> clearToken() async {
    clears++;
    token = null;
  }
}

/// Builds the `PostgrestException` postgrest throws for a failed rpc, so error
/// mapping can be tested against the real shape the app sees.
PostgrestException postgrestError(
  String code, {
  String message = '',
  String details = '',
}) {
  return PostgrestException(
    message: message,
    code: code,
    details: details,
  );
}
