import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:menukg_flutter/app/router/app_router.dart';
import 'package:menukg_flutter/features/customer/menu/presentation/pages/public_menu_page.dart';
import 'package:menukg_flutter/features/customer/reservations/data/models/reservation_model.dart';
import 'package:menukg_flutter/features/customer/reservations/data/repositories/reservation_repository.dart';
import 'package:menukg_flutter/features/customer/reservations/data/reservation_access_store.dart';
import 'package:menukg_flutter/features/customer/reservations/presentation/pages/my_reservations_page.dart';
import 'package:menukg_flutter/features/customer/reservations/presentation/pages/reservation_form_page.dart';
import 'package:menukg_flutter/features/customer/reservations/presentation/reservation_error_message.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/public_menu_test_data.dart';
import 'support/reservation_test_data.dart';

/// Pumps the form for a scanned table.
Future<void> pumpReservationForm(
  WidgetTester tester,
  ReservationRepository repository,
  ReservationAccessStore accessStore, {
  String qrToken = validQrToken,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      onGenerateRoute: AppRouter.onGenerateRoute,
      home: Builder(
        builder: (context) => ReservationFormPage(
          qrToken: qrToken,
          tableLabel: 'Table 12 · Window',
          restaurantName: 'Ala-Too',
          branchName: 'Center',
          repository: repository,
          accessStore: accessStore,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Pumps the guest's own reservation list.
Future<void> pumpMyReservations(
  WidgetTester tester,
  ReservationRepository repository,
  ReservationAccessStore accessStore,
) async {
  await tester.pumpWidget(
    MaterialApp(
      onGenerateRoute: AppRouter.onGenerateRoute,
      home: Builder(
        builder: (context) => MyReservationsPage(
          repository: repository,
          accessStore: accessStore,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('ReservationModel', () {
    test('parses a created reservation with its access token', () {
      final created = tryParseCreatedReservation(
        encodeRpcResult(buildCreatedReservationJson()),
      );

      expect(created, isNotNull);
      expect(created!.accessToken, guestAccessToken);
      expect(created.reservation.restaurantName, 'Ala-Too');
      expect(created.reservation.branchName, 'Center');
      expect(created.reservation.table.label, 'Table 12 · Window');
      expect(created.reservation.guestName, 'Askar');
      expect(created.reservation.guestCount, 2);
      expect(created.reservation.status, ReservationStatus.confirmed);
      expect(created.reservation.isCancelled, isFalse);
    });

    test('reads a date without shifting it and a time with seconds', () {
      final reservation = ReservationModel.fromJson(
        buildReservationJson(reservedDate: '2026-10-05', reservedTime: '19:00:00'),
      );

      expect(reservation.reservedDate, DateTime(2026, 10, 5));
      expect(reservation.reservedDate.hour, 0);
      expect(reservation.reservedTime, (hour: 19, minute: 0));
    });

    test('accepts a time without seconds', () {
      final reservation = ReservationModel.fromJson(
        buildReservationJson(reservedTime: '09:05'),
      );

      expect(reservation.reservedTime, (hour: 9, minute: 5));
    });

    test('parses the guest list and marks a cancelled one', () {
      final reservations = tryParseReservations(
        encodeRpcResult({
          'reservations': [
            buildReservationJson(),
            buildReservationJson(
              id: '1b0d6f0e-0000-4000-8000-000000000002',
              status: 'CANCELLED',
            ),
          ],
        }),
      );

      expect(reservations, hasLength(2));
      expect(reservations.first.status, ReservationStatus.confirmed);
      expect(reservations.last.isCancelled, isTrue);
    });

    test('an unknown status is never shown as confirmed', () {
      expect(
        () => ReservationModel.fromJson(buildReservationJson(status: 'SEATED')),
        throwsFormatException,
      );
    });

    test('an empty or unknown list payload reads as no reservations', () {
      expect(tryParseReservations(null), isEmpty);
      expect(tryParseReservations(''), isEmpty);
      expect(tryParseReservations('not json'), isEmpty);
      expect(tryParseReservations(encodeRpcResult({'reservations': []})), isEmpty);
      // An unknown guest token is reported by the database as an empty list.
      expect(tryParseReservations(encodeRpcResult({'reservations': []})), isEmpty);
    });

    test('a response without a token is not turned into a reservation', () {
      expect(tryParseCreatedReservation(null), isNull);
      expect(tryParseCreatedReservation('null'), isNull);
      expect(
        tryParseCreatedReservation(encodeRpcResult({'reservation': {}})),
        isNull,
      );
      expect(
        tryParseCreatedReservation(
          encodeRpcResult({'access_token': 'token-only'}),
        ),
        isNull,
      );
    });

    test('labels read the way a guest reads them', () {
      final reservation = ReservationModel.fromJson(buildReservationJson());

      expect(reservation.whenLabel, 'Mon, 5 Oct 2026 · 19:00');
      expect(reservation.partyLabel, 'Askar · 2 guests');
      expect(
        ReservationModel.fromJson(buildReservationJson(guestCount: 1))
            .partyLabel,
        'Askar · 1 guest',
      );
    });

    test('formats a day and a clock without any locale data', () {
      expect(
        formatReservationDay(DateTime(2026, 1, 1)),
        'Thu, 1 Jan 2026',
      );
      expect(formatReservationClock(hour: 9, minute: 5), '09:05');
      expect(formatReservationClock(hour: 0, minute: 0), '00:00');
      expect(formatReservationClock(hour: 19, minute: 30), '19:30');
    });
  });

  group('ReservationRepository', () {
    test('creates through the public rpc, never a table write', () async {
      late http.BaseRequest sent;
      Object? sentBody;
      final httpClient = RecordingHttpClient((request, body) async {
        sent = request;
        sentBody = body;
        return http.Response(encodeRpcResult(buildCreatedReservationJson()), 200);
      });
      final repository = ReservationRepository.withClient(
        buildSupabaseTestClient(httpClient),
      );

      final created = await repository.createReservation(
        qrToken: validQrToken,
        date: DateTime(2026, 10, 5),
        hour: 19,
        minute: 0,
        guestName: '  Askar  ',
        guestCount: 2,
      );

      expect(sent.url.path, '/rest/v1/rpc/create_table_reservation');
      expect(sent.method, 'POST');
      expect(jsonDecode(sentBody! as String), {
        'p_qr_token': validQrToken,
        'p_reserved_date': '2026-10-05',
        'p_reserved_time': '19:00',
        'p_guest_name': 'Askar',
        'p_guest_count': 2,
      });
      expect(created!.accessToken, guestAccessToken);
    });

    test('sends the stored token so a returning guest keeps one list', () async {
      Object? sentBody;
      final httpClient = RecordingHttpClient((request, body) async {
        sentBody = body;
        return http.Response(encodeRpcResult(buildCreatedReservationJson()), 200);
      });
      final repository = ReservationRepository.withClient(
        buildSupabaseTestClient(httpClient),
      );

      await repository.createReservation(
        qrToken: validQrToken,
        date: DateTime(2026, 10, 5),
        hour: 19,
        minute: 0,
        guestName: 'Askar',
        guestCount: 2,
        accessToken: '  $guestAccessToken  ',
      );

      expect(
        (jsonDecode(sentBody! as String) as Map<String, dynamic>)['p_access_token'],
        guestAccessToken,
      );
    });

    test('an unknown or inactive QR token resolves to nothing', () async {
      final httpClient = RecordingHttpClient((request, body) async {
        return http.Response('null', 200);
      });
      final repository = ReservationRepository.withClient(
        buildSupabaseTestClient(httpClient),
      );

      final created = await repository.createReservation(
        qrToken: '00000000-0000-4000-8000-000000000000',
        date: DateTime(2026, 10, 5),
        hour: 19,
        minute: 0,
        guestName: 'Askar',
        guestCount: 2,
      );

      expect(created, isNull);
    });

    test('a blank token, name or party never reaches the database', () async {
      var callCount = 0;
      final httpClient = RecordingHttpClient((request, body) async {
        callCount++;
        return http.Response('null', 200);
      });
      final repository = ReservationRepository.withClient(
        buildSupabaseTestClient(httpClient),
      );

      expect(
        await repository.createReservation(
          qrToken: '   ',
          date: DateTime(2026, 10, 5),
          hour: 19,
          minute: 0,
          guestName: 'Askar',
          guestCount: 2,
        ),
        isNull,
      );
      expect(
        await repository.createReservation(
          qrToken: validQrToken,
          date: DateTime(2026, 10, 5),
          hour: 19,
          minute: 0,
          guestName: '   ',
          guestCount: 2,
        ),
        isNull,
      );
      expect(
        await repository.createReservation(
          qrToken: validQrToken,
          date: DateTime(2026, 10, 5),
          hour: 19,
          minute: 0,
          guestName: 'Askar',
          guestCount: 0,
        ),
        isNull,
      );

      expect(callCount, 0);
    });

    test('reads own reservations with the stored token', () async {
      late http.BaseRequest sent;
      Object? sentBody;
      final httpClient = RecordingHttpClient((request, body) async {
        sent = request;
        sentBody = body;
        return http.Response(
          encodeRpcResult({
            'reservations': [buildReservationJson()],
          }),
          200,
        );
      });
      final repository = ReservationRepository.withClient(
        buildSupabaseTestClient(httpClient),
      );

      final reservations = await repository.getMyReservations(guestAccessToken);

      expect(sent.url.path, '/rest/v1/rpc/guest_reservations');
      expect(
        (jsonDecode(sentBody! as String) as Map<String, dynamic>)['p_access_token'],
        guestAccessToken,
      );
      expect(reservations, hasLength(1));
      expect(reservations.single.guestName, 'Askar');
    });

    test('no token means no reservations, and asks the database nothing', () async {
      var callCount = 0;
      final httpClient = RecordingHttpClient((request, body) async {
        callCount++;
        return http.Response('{}', 200);
      });
      final repository = ReservationRepository.withClient(
        buildSupabaseTestClient(httpClient),
      );

      expect(await repository.getMyReservations(null), isEmpty);
      expect(await repository.getMyReservations('   '), isEmpty);
      expect(callCount, 0);
    });

    test('cancels only through the token-scoped rpc', () async {
      late http.BaseRequest sent;
      Object? sentBody;
      final httpClient = RecordingHttpClient((request, body) async {
        sent = request;
        sentBody = body;
        return http.Response('true', 200);
      });
      final repository = ReservationRepository.withClient(
        buildSupabaseTestClient(httpClient),
      );

      final cancelled = await repository.cancelReservation(
        accessToken: guestAccessToken,
        reservationId: '8b8a7fe9-f457-494c-9f0a-e8f40ae9f136',
      );

      expect(sent.url.path, '/rest/v1/rpc/cancel_guest_reservation');
      expect(jsonDecode(sentBody! as String), {
        'p_access_token': guestAccessToken,
        'p_reservation_id': '8b8a7fe9-f457-494c-9f0a-e8f40ae9f136',
      });
      expect(cancelled, isTrue);
    });

    test("another guest's reservation id cancels nothing", () async {
      final httpClient = RecordingHttpClient((request, body) async {
        return http.Response('false', 200);
      });
      final repository = ReservationRepository.withClient(
        buildSupabaseTestClient(httpClient),
      );

      expect(
        await repository.cancelReservation(
          accessToken: otherGuestAccessToken,
          reservationId: '8b8a7fe9-f457-494c-9f0a-e8f40ae9f136',
        ),
        isFalse,
      );
    });

    test('a blank token or id cancels nothing', () async {
      var callCount = 0;
      final httpClient = RecordingHttpClient((request, body) async {
        callCount++;
        return http.Response('true', 200);
      });
      final repository = ReservationRepository.withClient(
        buildSupabaseTestClient(httpClient),
      );

      expect(
        await repository.cancelReservation(
          accessToken: '  ',
          reservationId: '8b8a7fe9-f457-494c-9f0a-e8f40ae9f136',
        ),
        isFalse,
      );
      expect(
        await repository.cancelReservation(
          accessToken: guestAccessToken,
          reservationId: '  ',
        ),
        isFalse,
      );
      expect(callCount, 0);
    });
  });

  group('reservation error messages', () {
    test('an already booked slot says so, and nothing about the database', () {
      final message = reservationErrorMessage(
        postgrestError(
          '23505',
          message: 'duplicate key value violates unique constraint '
              '"idx_reservations_active_slot"',
        ),
      );

      expect(message, 'That time is already taken. Please pick another time.');
      expect(message, isNot(contains('reservation')));
      expect(message.toLowerCase(), isNot(contains('sql')));
    });

    test('a rejected request points at the fields, not the schema', () {
      final message = reservationErrorMessage(
        postgrestError('P0001', message: 'invalid_reservation_request'),
      );

      expect(message, 'Please check the date, time, name and number of guests.');
      expect(message, isNot(contains('invalid_reservation_request')));
    });

    test('a missing grant does not leak a privilege error', () {
      for (final code in ['42501', '28000']) {
        final message = reservationErrorMessage(
          postgrestError(code, message: 'permission denied for function'),
        );
        expect(message, 'Reservations are not available right now.');
      }
    });

    test('a malformed token reads as an invalid QR code', () {
      expect(
        reservationErrorMessage(
          postgrestError('22P02', message: 'invalid input syntax for type uuid'),
        ),
        'This QR code is not valid.',
      );
      expect(
        reservationErrorMessage(
          postgrestError('PGRST202', message: 'JWT expired'),
        ),
        'Reservations are not available right now.',
      );
    });

    test('anything else falls back to a safe sentence', () {
      expect(
        reservationErrorMessage(
          postgrestError('08006', message: 'connection failure'),
        ),
        'We could not save your reservation. Please try again.',
      );
      expect(
        reservationErrorMessage(StateError('boom')),
        'We could not save your reservation. Please try again.',
      );
      expect(
        reservationListErrorMessage(StateError('boom')),
        'We could not load your reservations. Please try again.',
      );
    });

    test('the unavailable table message names no table or restaurant', () {
      expect(
        reservationQrUnavailableMessage,
        'This table cannot be reserved right now.',
      );
    });
  });

  group('DeviceReservationAccessStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('is empty on a device that never reserved', () async {
      const store = DeviceReservationAccessStore();

      expect(await store.readToken(), isNull);
    });

    test('keeps the token between reads, which is what survives a restart', () async {
      const store = DeviceReservationAccessStore();

      await store.writeToken(guestAccessToken);
      expect(await store.readToken(), guestAccessToken);

      // A fresh instance stands in for the next app launch.
      expect(await const DeviceReservationAccessStore().readToken(),
          guestAccessToken);
    });

    test('trims what it stores so a stray space cannot lock a guest out', () async {
      const store = DeviceReservationAccessStore();

      await store.writeToken('  $guestAccessToken  ');
      expect(await store.readToken(), guestAccessToken);
    });

    test('clearing forgets the token', () async {
      const store = DeviceReservationAccessStore();
      await store.writeToken(guestAccessToken);

      await store.clearToken();
      expect(await store.readToken(), isNull);
    });

    test('an empty or blank stored value reads as no token', () async {
      SharedPreferences.setMockInitialValues({
        DeviceReservationAccessStore.tokenKey: '   ',
      });

      expect(await const DeviceReservationAccessStore().readToken(), isNull);
    });
  });

  group('ReservationFormPage', () {
    testWidgets('books the scanned table and stores the token', (tester) async {
      final repository = FakeReservationRepository(
        created: tryParseCreatedReservation(
          encodeRpcResult(buildCreatedReservationJson()),
        ),
      );
      final store = MemoryReservationAccessStore();

      await pumpReservationForm(tester, repository, store);

      await tester.enterText(
        find.byKey(const Key('reservationGuestNameField')),
        'Askar',
      );
      await tester.tap(find.byKey(const Key('reservationGuestCountIncrease')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('reservationSubmitButton')));
      await tester.pumpAndSettle();

      final call = repository.createCalls.single;
      expect(call['qrToken'], validQrToken);
      expect(call['guestName'], 'Askar');
      expect(call['guestCount'], 2);
      // The form asked for no restaurant, branch or table id, only the token.
      expect(store.token, guestAccessToken);
      expect(store.writes, 1);
      expect(find.byKey(const Key('reservationCreatedTitle')), findsOneWidget);
      expect(find.text('Mon, 5 Oct 2026 · 19:00'), findsOneWidget);
    });

    testWidgets('sends the stored token so a returning guest keeps one list', (
      tester,
    ) async {
      final repository = FakeReservationRepository(
        created: tryParseCreatedReservation(
          encodeRpcResult(buildCreatedReservationJson()),
        ),
      );
      final store = MemoryReservationAccessStore(guestAccessToken);

      await pumpReservationForm(tester, repository, store);
      await tester.enterText(
        find.byKey(const Key('reservationGuestNameField')),
        'Askar',
      );
      await tester.tap(find.byKey(const Key('reservationSubmitButton')));
      await tester.pumpAndSettle();

      expect(repository.createCalls.single['accessToken'], guestAccessToken);
      expect(store.writes, 1);
    });

    testWidgets('shows the table it is booking, as labels only', (
      tester,
    ) async {
      await pumpReservationForm(
        tester,
        FakeReservationRepository(),
        MemoryReservationAccessStore(),
      );

      expect(find.text('Ala-Too'), findsOneWidget);
      expect(find.text('Center · Table 12 · Window'), findsOneWidget);
    });

    testWidgets('refuses to submit without a name', (tester) async {
      final repository = FakeReservationRepository();

      await pumpReservationForm(tester, repository, MemoryReservationAccessStore());
      await tester.tap(find.byKey(const Key('reservationSubmitButton')));
      await tester.pumpAndSettle();

      expect(repository.createCalls, isEmpty);
      expect(find.text('Please enter your name.'), findsOneWidget);
    });

    testWidgets('a table that cannot be resolved says so', (tester) async {
      final repository = FakeReservationRepository();

      await pumpReservationForm(tester, repository, MemoryReservationAccessStore());
      await tester.enterText(
        find.byKey(const Key('reservationGuestNameField')),
        'Askar',
      );
      await tester.tap(find.byKey(const Key('reservationSubmitButton')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('reservationErrorMessage')), findsOneWidget);
      expect(find.text(reservationQrUnavailableMessage), findsOneWidget);
      expect(find.byKey(const Key('reservationCreatedTitle')), findsNothing);
    });

    testWidgets('a taken slot is reported as a time problem, not a crash', (
      tester,
    ) async {
      final repository = FakeReservationRepository(
        createError: postgrestError(
          '23505',
          message: 'duplicate key value violates unique constraint '
              '"idx_reservations_active_slot"',
        ),
      );
      final store = MemoryReservationAccessStore();

      await pumpReservationForm(tester, repository, store);
      await tester.enterText(
        find.byKey(const Key('reservationGuestNameField')),
        'Askar',
      );
      await tester.tap(find.byKey(const Key('reservationSubmitButton')));
      await tester.pumpAndSettle();

      expect(
        find.text('That time is already taken. Please pick another time.'),
        findsOneWidget,
      );
      // Nothing was created, so no token is stored.
      expect(store.writes, 0);
    });

    testWidgets('a party larger than the table is reported as a field problem', (
      tester,
    ) async {
      final repository = FakeReservationRepository(
        createError: postgrestError('P0001', message: 'invalid_reservation_request'),
      );

      await pumpReservationForm(tester, repository, MemoryReservationAccessStore());
      await tester.enterText(
        find.byKey(const Key('reservationGuestNameField')),
        'Askar',
      );
      await tester.tap(find.byKey(const Key('reservationSubmitButton')));
      await tester.pumpAndSettle();

      expect(
        find.text('Please check the date, time, name and number of guests.'),
        findsOneWidget,
      );
    });

    testWidgets('never promises the restaurant was told', (tester) async {
      await pumpReservationForm(
        tester,
        FakeReservationRepository(),
        MemoryReservationAccessStore(),
      );

      expect(find.byKey(const Key('reservationFootnote')), findsOneWidget);
      expect(
        find.textContaining('Nothing is sent to the restaurant yet.'),
        findsOneWidget,
      );
    });

    testWidgets('opens the guest list after a booking', (tester) async {
      final repository = FakeReservationRepository(
        created: tryParseCreatedReservation(
          encodeRpcResult(buildCreatedReservationJson()),
        ),
      );

      await pumpReservationForm(
        tester,
        repository,
        MemoryReservationAccessStore(),
      );
      await tester.enterText(
        find.byKey(const Key('reservationGuestNameField')),
        'Askar',
      );
      await tester.tap(find.byKey(const Key('reservationSubmitButton')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('reservationViewMineButton')));
      await tester.pumpAndSettle();

      expect(find.text('My reservations'), findsOneWidget);
    });
  });

  group('MyReservationsPage', () {
    testWidgets('says a device with no token has no reservations', (tester) async {
      final repository = FakeReservationRepository();

      await pumpMyReservations(
        tester,
        repository,
        MemoryReservationAccessStore(),
      );

      // The repository is asked with no token, and answers without a request.
      expect(repository.listCalls, [null]);
      expect(find.byKey(const Key('reservationsEmptyState')), findsOneWidget);
      expect(find.textContaining('No reservations on this device yet.'),
          findsOneWidget);
    });

    testWidgets('lists the stored guest\'s reservations', (tester) async {
      final repository = FakeReservationRepository(
        reservations: [
          ReservationModel.fromJson(buildReservationJson()),
          ReservationModel.fromJson(
            buildReservationJson(
              id: '1b0d6f0e-0000-4000-8000-000000000002',
              reservedDate: '2026-10-06',
              reservedTime: '13:30:00',
              guestCount: 1,
            ),
          ),
        ],
      );

      await pumpMyReservations(
        tester,
        repository,
        MemoryReservationAccessStore(guestAccessToken),
      );

      expect(repository.listCalls, [guestAccessToken]);
      expect(find.text('Mon, 5 Oct 2026 · 19:00'), findsOneWidget);
      expect(find.text('Tue, 6 Oct 2026 · 13:30'), findsOneWidget);
      expect(find.text('Askar · 2 guests · Table 12 · Window'), findsOneWidget);
      expect(find.text('Askar · 1 guest · Table 12 · Window'), findsOneWidget);
    });

    testWidgets('offers a retry when the list cannot be loaded', (tester) async {
      final repository = FakeReservationRepository(
        listError: StateError('network down'),
      );

      await pumpMyReservations(
        tester,
        repository,
        MemoryReservationAccessStore(guestAccessToken),
      );

      expect(
        find.text('We could not load your reservations. Please try again.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('retryReservationsButton')), findsOneWidget);
    });

    testWidgets('cancels only after the guest confirms', (tester) async {
      final reservation = ReservationModel.fromJson(buildReservationJson());
      final repository = FakeReservationRepository(reservations: [reservation]);
      final store = MemoryReservationAccessStore(guestAccessToken);

      await pumpMyReservations(tester, repository, store);
      await tester.tap(
        find.byKey(Key('cancelReservation_${reservation.id}')),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('cancelReservationDialog')), findsOneWidget);
      expect(repository.cancelCalls, isEmpty);

      await tester.tap(find.text('Keep it'));
      await tester.pumpAndSettle();

      expect(repository.cancelCalls, isEmpty);
    });

    testWidgets('a confirmed cancellation goes through the token-scoped rpc', (
      tester,
    ) async {
      final reservation = ReservationModel.fromJson(buildReservationJson());
      final repository = FakeReservationRepository(reservations: [reservation]);
      final store = MemoryReservationAccessStore(guestAccessToken);

      await pumpMyReservations(tester, repository, store);
      await tester.tap(
        find.byKey(Key('cancelReservation_${reservation.id}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirmCancelReservationButton')));
      await tester.pumpAndSettle();

      expect(repository.cancelCalls, [
        {
          'accessToken': guestAccessToken,
          'reservationId': reservation.id,
        },
      ]);
      // The card stays, marked as cancelled, and can no longer be cancelled.
      expect(
        find.byKey(Key('reservationCancelled_${reservation.id}')),
        findsOneWidget,
      );
      expect(find.text(reservationCancelledMessage), findsWidgets);
      expect(
        find.byKey(Key('cancelReservation_${reservation.id}')),
        findsNothing,
      );
    });

    testWidgets('a cancellation the database refuses changes nothing', (
      tester,
    ) async {
      final reservation = ReservationModel.fromJson(buildReservationJson());
      final repository = FakeReservationRepository(
        reservations: [reservation],
        cancelled: false,
      );

      await pumpMyReservations(
        tester,
        repository,
        MemoryReservationAccessStore(guestAccessToken),
      );
      await tester.tap(
        find.byKey(Key('cancelReservation_${reservation.id}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirmCancelReservationButton')));
      await tester.pumpAndSettle();

      // Still confirmed, and still cancellable, because nothing changed.
      expect(
        find.byKey(Key('cancelReservation_${reservation.id}')),
        findsOneWidget,
      );
    });

    testWidgets('a cancellation failure is reported safely', (tester) async {
      final reservation = ReservationModel.fromJson(buildReservationJson());
      final repository = FakeReservationRepository(
        reservations: [reservation],
        cancelError: postgrestError('42501', message: 'permission denied'),
      );

      await pumpMyReservations(
        tester,
        repository,
        MemoryReservationAccessStore(guestAccessToken),
      );
      await tester.tap(
        find.byKey(Key('cancelReservation_${reservation.id}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirmCancelReservationButton')));
      await tester.pumpAndSettle();

      expect(find.text('Reservations are not available right now.'),
          findsOneWidget);
    });
  });

  group('PublicMenuPage reservation entry', () {
    testWidgets('offers a reservation for the scanned table', (tester) async {
      final reservationRepository = FakeReservationRepository();
      final accessStore = MemoryReservationAccessStore();

      await tester.pumpWidget(
        MaterialApp(
          onGenerateRoute: AppRouter.onGenerateRoute,
          home: Builder(
            builder: (context) => PublicMenuPage(
              qrToken: validQrToken,
              repository: FakePublicMenuRepository(buildMenuJson()),
              reservationRepository: reservationRepository,
              reservationAccessStore: accessStore,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('reserveTableButton')), findsOneWidget);
      // The cart entry point still exists next to it.
      expect(find.byKey(const Key('cartButton')), findsOneWidget);

      await tester.tap(find.byKey(const Key('reserveTableButton')));
      await tester.pumpAndSettle();

      expect(find.text('Reserve a table'), findsOneWidget);
      expect(find.text('Center · Table 12 · Window'), findsOneWidget);
    });

    testWidgets('reaches the guest list without a new route', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          onGenerateRoute: AppRouter.onGenerateRoute,
          home: Builder(
            builder: (context) => PublicMenuPage(
              qrToken: validQrToken,
              repository: FakePublicMenuRepository(buildMenuJson()),
              reservationRepository: FakeReservationRepository(
                reservations: [ReservationModel.fromJson(buildReservationJson())],
              ),
              reservationAccessStore: MemoryReservationAccessStore(
                guestAccessToken,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const Key('myReservationsButton')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('myReservationsButton')));
      await tester.pumpAndSettle();

      expect(find.text('My reservations'), findsOneWidget);
      expect(find.text('Mon, 5 Oct 2026 · 19:00'), findsOneWidget);
    });

    testWidgets('a menu with no dishes offers no reservation entry', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          onGenerateRoute: AppRouter.onGenerateRoute,
          home: Builder(
            builder: (context) => PublicMenuPage(
              qrToken: validQrToken,
              repository: FakePublicMenuRepository(
                buildMenuJson(categories: []),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('reserveTableButton')), findsNothing);
      expect(find.byKey(const Key('cartButton')), findsNothing);
    });
  });
}
