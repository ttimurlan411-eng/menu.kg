import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:menukg_flutter/features/customer/reservations/data/models/reservation_model.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/models/staff_reservation_model.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/repositories/staff_reservation_repository.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/staff_reservation_error_message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'support/public_menu_test_data.dart';
import 'support/staff_order_test_data.dart';
import 'support/staff_reservation_test_data.dart';

void main() {
  group('StaffReservationModel', () {
    test('parses a reservation with its branch, table and booking', () {
      final reservation = StaffReservationModel.fromJson(
        buildStaffReservationJson(),
      );

      expect(reservation.id, reservationId);
      expect(reservation.restaurantId, restaurantA);
      expect(reservation.branchId, centerBranch);
      expect(reservation.tableId, reservationTableId);
      expect(reservation.reservedDate, DateTime(2026, 10, 5));
      expect(reservation.reservedTime, (hour: 19, minute: 0));
      expect(reservation.guestName, 'Askar');
      expect(reservation.guestCount, 2);
      expect(reservation.status, ReservationStatus.confirmed);
      expect(reservation.createdAt, DateTime.parse(reservationCreatedAt));
      expect(reservation.updatedAt, DateTime.parse(reservationUpdatedAt));
    });

    test('a reservation with no table is still readable', () {
      final reservation = StaffReservationModel.fromJson(
        buildStaffReservationJson(tableId: null),
      );

      expect(reservation.tableId, isNull);
    });

    test('formats the booking and the party as staff read them', () {
      final reservation = StaffReservationModel.fromJson(
        buildStaffReservationJson(),
      );

      expect(reservation.whenLabel, 'Mon, 5 Oct 2026 · 19:00');
      expect(reservation.partyLabel, 'Askar · 2 guests');
      expect(reservation.isCancelled, isFalse);
    });

    test('a single guest is spoken about in the singular', () {
      final reservation = StaffReservationModel.fromJson(
        buildStaffReservationJson(guestCount: 1),
      );

      expect(reservation.partyLabel, 'Askar · 1 guest');
    });

    test('cancelling keeps the booking and the party', () {
      final reservation = StaffReservationModel.fromJson(
        buildStaffReservationJson(),
      );
      final cancelled = reservation.withStatus(
        ReservationStatus.cancelled,
        updatedAt: DateTime.parse(reservationUpdatedAt),
      );

      expect(cancelled.status, ReservationStatus.cancelled);
      expect(cancelled.isCancelled, isTrue);
      expect(cancelled.updatedAt, DateTime.parse(reservationUpdatedAt));
      expect(cancelled.id, reservation.id);
      expect(cancelled.restaurantId, reservation.restaurantId);
      expect(cancelled.branchId, reservation.branchId);
      expect(cancelled.tableId, reservation.tableId);
      expect(cancelled.reservedDate, reservation.reservedDate);
      expect(cancelled.reservedTime, reservation.reservedTime);
      expect(cancelled.guestCount, reservation.guestCount);
      expect(cancelled.createdAt, reservation.createdAt);
      // The reservation itself is untouched, so a screen cannot lose the state
      // it had.
      expect(reservation.status, ReservationStatus.confirmed);
    });

    test('an unknown status is refused rather than guessed at', () {
      expect(
        () => StaffReservationModel.fromJson(
          buildStaffReservationJson(status: 'REFUNDED'),
        ),
        throwsFormatException,
      );
    });

    test('ignores an access token it must never hold', () {
      // The staff payload carries none; a token placed in it anyway is simply
      // not a field of this model, so it cannot be read out of one.
      final json = buildStaffReservationJson()
        ..['access_token'] = 'guest-secret-token';

      final reservation = StaffReservationModel.fromJson(json);

      expect(reservation.id, reservationId);
      expect(reservation.guestName, 'Askar');
      expect(reservation.tableId, reservationTableId);
    });
  });

  group('tryParseStaffReservations', () {
    test('parses the payload the database sends', () {
      final reservations = tryParseStaffReservations(
        encodeReservationRpcResult(buildStaffReservationsJson()),
        restaurantId: restaurantA,
      );

      expect(reservations, hasLength(1));
      expect(reservations.single.status, ReservationStatus.confirmed);
      expect(reservations.single.whenLabel, 'Mon, 5 Oct 2026 · 19:00');
    });

    test('accepts a payload delivered as a string', () {
      final reservations = tryParseStaffReservations(
        jsonEncode(buildStaffReservationsJson()),
        restaurantId: restaurantA,
      );

      expect(reservations, hasLength(1));
    });

    test('skips a reservation it cannot read and keeps the ones around it', () {
      final reservations = tryParseStaffReservations(
        encodeReservationRpcResult(
          buildStaffReservationsJson(
            reservations: [
              buildStaffReservationJson(guestName: 'First'),
              buildStaffReservationJson(guestName: 'Second', status: 'REFUNDED'),
              buildStaffReservationJson(guestName: 'Third'),
            ],
          ),
        ),
        restaurantId: restaurantA,
      );

      expect(reservations.map((reservation) => reservation.guestName), [
        'First',
        'Third',
      ]);
    });

    test('skips entries that are not reservations at all', () {
      final reservations = tryParseStaffReservations(
        encodeReservationRpcResult(
          buildStaffReservationsJson(
            reservations: ['not a reservation', 42, buildStaffReservationJson()],
          ),
        ),
        restaurantId: restaurantA,
      );

      expect(reservations, hasLength(1));
    });

    test('refuses a payload that names another restaurant', () {
      final reservations = tryParseStaffReservations(
        encodeReservationRpcResult(
          buildStaffReservationsJson(restaurantId: restaurantB),
        ),
        restaurantId: restaurantA,
      );

      expect(reservations, isEmpty);
    });

    test('reads nothing from an answer it cannot understand', () {
      for (final response in <Object?>[
        null,
        '',
        '   ',
        'not json',
        jsonEncode('a string, not an object'),
        jsonEncode({'reservations': 'not a list'}),
        jsonEncode({'restaurant_id': restaurantA}),
        42,
      ]) {
        expect(
          tryParseStaffReservations(response, restaurantId: restaurantA),
          isEmpty,
          reason: 'nothing is read from $response',
        );
      }
    });
  });

  group('StaffReservationRepository.getReservations', () {
    test('makes no request when nobody is signed in', () async {
      final httpClient = staffHttpClient(
        payload: buildStaffReservationsJson(),
      );
      final repository = StaffReservationRepository.withClient(
        buildSupabaseTestClient(httpClient),
      );

      expect(
        await repository.getReservations(restaurantId: restaurantA),
        isEmpty,
      );
      expect(httpClient.requestBodies, isEmpty);
    });

    test('makes no request for a blank restaurant', () async {
      final httpClient = staffHttpClient(
        payload: buildStaffReservationsJson(),
      );
      final repository = StaffReservationRepository.withClient(
        await signedInStaffClient(httpClient),
      );

      expect(await repository.getReservations(restaurantId: '  '), isEmpty);
      expect(
        httpClient.requestBodies.where((body) => body!.contains('p_')),
        isEmpty,
      );
    });

    test('sends the restaurant and a limit, and nothing else', () async {
      final httpClient = staffHttpClient(
        payload: buildStaffReservationsJson(),
      );
      final repository = StaffReservationRepository.withClient(
        await signedInStaffClient(httpClient),
      );

      final reservations = await repository.getReservations(
        restaurantId: restaurantA,
      );

      expect(reservations, hasLength(1));
      expect(
        lastRpcBody(httpClient).keys.toSet(),
        {'p_restaurant_id', 'p_limit'},
        reason: 'a whole-restaurant read names no branch and no day',
      );
      expect(lastRpcBody(httpClient)['p_restaurant_id'], restaurantA);
      expect(
        lastRpcBody(httpClient)['p_limit'],
        StaffReservationRepository.defaultLimit,
      );
    });

    test('sends a branch when one is given, and omits a blank one', () async {
      final httpClient = staffHttpClient(
        payload: buildStaffReservationsJson(branchId: centerBranch),
      );
      final repository = StaffReservationRepository.withClient(
        await signedInStaffClient(httpClient),
      );

      await repository.getReservations(
        restaurantId: restaurantA,
        branchId: centerBranch,
      );

      expect(lastRpcBody(httpClient)['p_branch_id'], centerBranch);

      await repository.getReservations(
        restaurantId: restaurantA,
        branchId: '   ',
      );

      expect(
        lastRpcBody(httpClient).containsKey('p_branch_id'),
        isFalse,
        reason: 'a blank branch is no branch, not a branch that matches nothing',
      );
    });

    test('sends a day when one is given, and omits it otherwise', () async {
      final httpClient = staffHttpClient(
        payload: buildStaffReservationsJson(date: '2026-10-05'),
      );
      final repository = StaffReservationRepository.withClient(
        await signedInStaffClient(httpClient),
      );

      await repository.getReservations(
        restaurantId: restaurantA,
        date: DateTime(2026, 10, 5),
      );

      expect(lastRpcBody(httpClient)['p_date'], '2026-10-05');

      await repository.getReservations(restaurantId: restaurantA);

      expect(
        lastRpcBody(httpClient).containsKey('p_date'),
        isFalse,
        reason: 'no day means every day the restaurant has bookings',
      );
    });

    test('never sends a token, a user id or a status', () async {
      final httpClient = staffHttpClient(
        payload: buildStaffReservationsJson(),
      );
      final repository = StaffReservationRepository.withClient(
        await signedInStaffClient(httpClient),
      );

      await repository.getReservations(restaurantId: restaurantA);

      final body = httpClient.requestBodies.firstWhere(
        (body) => body!.contains('p_restaurant_id'),
      );
      expect(body, isNot(contains('access_token')));
      expect(body, isNot(contains(staffUserId)));
      expect(body, isNot(contains('status')));
    });

    test('clamps the limit to the range the database accepts', () async {
      final httpClient = staffHttpClient(
        payload: buildStaffReservationsJson(),
      );
      final repository = StaffReservationRepository.withClient(
        await signedInStaffClient(httpClient),
      );

      await repository.getReservations(restaurantId: restaurantA, limit: 0);
      expect(lastRpcBody(httpClient)['p_limit'], 1);

      await repository.getReservations(restaurantId: restaurantA, limit: -3);
      expect(lastRpcBody(httpClient)['p_limit'], 1);

      await repository.getReservations(
        restaurantId: restaurantA,
        limit: 100000,
      );
      expect(
        lastRpcBody(httpClient)['p_limit'],
        StaffReservationRepository.maxLimit,
      );
    });

    test('refuses an answer that belongs to another restaurant', () async {
      final httpClient = staffHttpClient(
        payload: buildStaffReservationsJson(restaurantId: restaurantB),
      );
      final repository = StaffReservationRepository.withClient(
        await signedInStaffClient(httpClient),
      );

      expect(
        await repository.getReservations(restaurantId: restaurantA),
        isEmpty,
      );
    });
  });

  group('StaffReservationRepository.setReservationStatus', () {
    test('makes no request when nobody is signed in', () async {
      final httpClient = staffHttpClient(
        payload: buildStaffReservationStatusUpdateJson(),
      );
      final repository = StaffReservationRepository.withClient(
        buildSupabaseTestClient(httpClient),
      );

      final update = await repository.setReservationStatus(
        reservationId: reservationId,
        status: ReservationStatus.cancelled,
      );

      expect(update, isNull);
      expect(httpClient.requestBodies, isEmpty);
    });

    test('makes no request for a blank reservation id', () async {
      final httpClient = staffHttpClient(
        payload: buildStaffReservationStatusUpdateJson(),
      );
      final repository = StaffReservationRepository.withClient(
        await signedInStaffClient(httpClient),
      );

      final update = await repository.setReservationStatus(
        reservationId: '   ',
        status: ReservationStatus.cancelled,
      );

      expect(update, isNull);
      expect(
        httpClient.requestBodies.where((body) => body!.contains('p_')),
        isEmpty,
      );
    });

    test('sends the reservation id and the stored status, and nothing else', () async {
      final httpClient = staffHttpClient(
        payload: buildStaffReservationStatusUpdateJson(),
      );
      final repository = StaffReservationRepository.withClient(
        await signedInStaffClient(httpClient),
      );

      await repository.setReservationStatus(
        reservationId: reservationId,
        status: ReservationStatus.cancelled,
      );

      // No restaurant id: the database reads it from the reservation, so a
      // screen has no argument with which to name another restaurant's bookings.
      expect(
        lastRpcBody(httpClient).keys.toSet(),
        {'p_reservation_id', 'p_new_status'},
      );
      expect(lastRpcBody(httpClient)['p_reservation_id'], reservationId);
      expect(lastRpcBody(httpClient)['p_new_status'], 'CANCELLED');
      expect(httpClient.requestBodies.last, isNot(contains(restaurantA)));
      expect(httpClient.requestBodies.last, isNot(contains(staffUserId)));
    });

    test('a move to a status the phase does not define is sent verbatim', () async {
      // The repository does not filter the move: hiding an impossible move is a
      // convenience, and the database refusing it is the rule.
      final httpClient = staffHttpClient(
        payload: buildStaffReservationStatusUpdateJson(),
      );
      final repository = StaffReservationRepository.withClient(
        await signedInStaffClient(httpClient),
      );

      await repository.setReservationStatus(
        reservationId: reservationId,
        status: ReservationStatus.confirmed,
      );

      expect(lastRpcBody(httpClient)['p_new_status'], 'CONFIRMED');
    });

    test('reports what the database stored', () async {
      final httpClient = staffHttpClient(
        payload: buildStaffReservationStatusUpdateJson(status: 'CANCELLED'),
      );
      final repository = StaffReservationRepository.withClient(
        await signedInStaffClient(httpClient),
      );

      final update = await repository.setReservationStatus(
        reservationId: reservationId,
        status: ReservationStatus.cancelled,
      );

      expect(update, isNotNull);
      expect(update!.reservationId, reservationId);
      expect(update.status, ReservationStatus.cancelled);
      expect(update.updatedAt, DateTime.parse(reservationUpdatedAt));
    });

    test('claims nothing when the answer is not a status change', () async {
      for (final payload in <Object?>[
        null,
        'not json',
        jsonEncode({'id': reservationId}),
        jsonEncode({'status': 'CANCELLED'}),
        jsonEncode(buildStaffReservationStatusUpdateJson(status: 'REFUNDED')),
      ]) {
        final httpClient = staffHttpClient(payload: payload);
        final repository = StaffReservationRepository.withClient(
          await signedInStaffClient(httpClient),
        );

        expect(
          await repository.setReservationStatus(
            reservationId: reservationId,
            status: ReservationStatus.cancelled,
          ),
          isNull,
          reason: 'nothing is claimed from $payload',
        );
      }
    });

    test('lets a refusal through instead of hiding it', () async {
      final httpClient = staffHttpClient(
        payload: {
          'code': '42501',
          'message': 'staff_reservation_access_denied',
          'details': null,
          'hint': null,
        },
        statusCode: 400,
      );
      final repository = StaffReservationRepository.withClient(
        await signedInStaffClient(httpClient),
      );

      await expectLater(
        repository.setReservationStatus(
          reservationId: reservationId,
          status: ReservationStatus.cancelled,
        ),
        throwsA(
          isA<PostgrestException>().having(
            (error) => error.message,
            'message',
            'staff_reservation_access_denied',
          ),
        ),
      );
    });
  });

  group('staff reservation error messages', () {
    test('an ended session is reported as a sign-in problem', () {
      for (final message in [
        staffReservationListErrorMessage(
          reservationPostgrestError(
            '28000',
            message: 'Authentication is required to read restaurant reservations.',
          ),
        ),
        staffReservationStatusErrorMessage(
          reservationPostgrestError(
            '28000',
            message: 'Authentication is required to change a reservation status.',
          ),
        ),
      ]) {
        expect(message, 'Your session has ended. Please sign in again.');
      }
    });

    test('a refused read is reported as a permission problem', () {
      final message = staffReservationListErrorMessage(
        reservationPostgrestError(
          '42501',
          message: 'staff_reservation_access_denied',
        ),
      );

      expect(message, 'You do not have permission to view these reservations.');
      expect(message, isNot(contains('staff_reservation')));
      expect(message, isNot(contains('denied')));
    });

    test('a refused change is reported as a permission problem', () {
      expect(
        staffReservationStatusErrorMessage(
          reservationPostgrestError(
            '42501',
            message: 'staff_reservation_access_denied',
          ),
        ),
        'You do not have permission to change this reservation.',
      );
    });

    test('a refused move is reported as the rule, not as a permission problem', () {
      expect(
        staffReservationStatusErrorMessage(
          reservationPostgrestError(
            'P0001',
            message: 'invalid_reservation_status_transition',
          ),
        ),
        'This reservation cannot move to that status.',
      );
    });

    test('a status that does not exist is reported as its own problem', () {
      // The transition message begins with these words, so the shorter one has
      // to be checked second or an impossible move is reported as a status that
      // is unknown.
      expect(
        staffReservationStatusErrorMessage(
          reservationPostgrestError(
            'P0001',
            message: 'invalid_reservation_status',
          ),
        ),
        'That is not a status this reservation can be in.',
      );
      expect(
        staffReservationStatusErrorMessage(
          reservationPostgrestError(
            'P0001',
            message: 'invalid_reservation_status_transition',
          ),
        ),
        isNot('That is not a status this reservation can be in.'),
      );
    });

    test('a malformed request is reported as something to correct', () {
      expect(
        staffReservationStatusErrorMessage(
          reservationPostgrestError(
            '22023',
            message: 'A reservation id and a status are required.',
          ),
        ),
        'Choose a reservation and a status first.',
      );
    });

    test('anything else falls back to safe wording that echoes nothing', () {
      const leak = 'relation public.reservations does not exist for staff_member';

      expect(
        staffReservationListErrorMessage(
          reservationPostgrestError('42P01', message: leak),
        ),
        'We could not load these reservations. Please try again.',
      );
      expect(
        staffReservationStatusErrorMessage(
          reservationPostgrestError('42P01', message: leak),
        ),
        'We could not change this reservation. Please try again.',
      );
      expect(
        staffReservationStatusErrorMessage(StateError(leak)),
        'We could not change this reservation. Please try again.',
      );
      expect(
        staffReservationListErrorMessage(StateError(leak)),
        'We could not load these reservations. Please try again.',
      );
    });
  });
}
