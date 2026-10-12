import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:menukg_flutter/features/customer/orders/data/models/order_model.dart';
import 'package:menukg_flutter/features/customer/reservations/data/models/reservation_model.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/models/staff_reservation_model.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/models/table_model.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/repositories/staff_reservation_repository.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/repositories/table_repository.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/pages/bookings_page.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/pages/staff_reservation_details_page.dart';

import 'support/staff_order_test_data.dart';
import 'support/staff_reservation_test_data.dart';

/// The credential a guest reservation can be read back with, which must never
/// reach a staff screen.
const String guestAccessToken = 'a1a1a1a1-1111-4111-8111-111111111111';

/// A table as the bookings page resolves its label from `tables`.
TableModel buildTable({
  String id = reservationTableId,
  String tableNumber = '12',
  String? name = 'Window',
}) {
  return TableModel(
    id: id,
    restaurantId: restaurantA,
    branchId: centerBranch,
    tableNumber: tableNumber,
    name: name,
    capacity: 4,
    zone: null,
    status: 'AVAILABLE',
    qrToken: 'qr-token',
    isActive: true,
    createdAt: DateTime.parse(reservationCreatedAt),
    updatedAt: DateTime.parse(reservationUpdatedAt),
  );
}

/// Serves fixed reservations and records what a screen asked for.
///
/// The repository is the whole of a screen's access to the database, so
/// recording its arguments is how a test proves a screen asked for one day's
/// reservations and for nothing else.
class _FakeStaffReservationRepository extends StaffReservationRepository {
  _FakeStaffReservationRepository({
    List<List<StaffReservationModel>>? responses,
    this.listError,
    this.statusError,
  }) : responses = responses ?? <List<StaffReservationModel>>[const []];

  /// One list per read, in order; the last one repeats for any read after it.
  List<List<StaffReservationModel>> responses;

  /// Thrown by [getReservations], standing in for a refused or failed read.
  Object? listError;

  /// Thrown by [setReservationStatus], standing in for a refused cancellation.
  Object? statusError;

  int listCalls = 0;
  final List<({DateTime? date, String? branchId, int limit})> listArguments = [];
  final List<({String reservationId, ReservationStatus status})> statusCalls =
      [];

  @override
  Future<List<StaffReservationModel>> getReservations({
    required String restaurantId,
    String? branchId,
    DateTime? date,
    int limit = StaffReservationRepository.defaultLimit,
  }) async {
    listCalls++;
    listArguments.add((date: date, branchId: branchId, limit: limit));

    if (listError != null) {
      throw listError!;
    }

    final index = listCalls - 1;
    return index < responses.length ? responses[index] : responses.last;
  }

  @override
  Future<StaffReservationStatusUpdate?> setReservationStatus({
    required String reservationId,
    required ReservationStatus status,
  }) async {
    statusCalls.add((reservationId: reservationId, status: status));

    if (statusError != null) {
      throw statusError!;
    }

    return StaffReservationStatusUpdate(
      reservationId: reservationId,
      status: status,
      updatedAt: DateTime.parse(reservationUpdatedAt),
    );
  }
}

/// A read that has not answered yet, for the loading state.
class _PendingStaffReservationRepository extends StaffReservationRepository {
  final Completer<List<StaffReservationModel>> _completer =
      Completer<List<StaffReservationModel>>();

  void answer(List<StaffReservationModel> reservations) =>
      _completer.complete(reservations);

  @override
  Future<List<StaffReservationModel>> getReservations({
    required String restaurantId,
    String? branchId,
    DateTime? date,
    int limit = StaffReservationRepository.defaultLimit,
  }) => _completer.future;
}

/// Serves fixed tables and records the branch a read was narrowed to.
class _FakeTableRepository extends TableRepository {
  _FakeTableRepository([this.tables = const []]);

  final List<TableModel> tables;
  int calls = 0;
  final List<String?> branches = [];

  @override
  Future<List<TableModel>> getTables(String restaurantId, {String? branchId}) async {
    calls++;
    branches.add(branchId);
    return tables;
  }
}

/// Pumps the bookings list on its own.
Future<void> pumpBookingsPage(
  WidgetTester tester,
  StaffReservationRepository repository, {
  List<TableModel> tables = const [],
  String? branchId,
  TableRepository? tableRepository,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: BookingsPage(
        restaurantId: restaurantA,
        branchId: branchId,
        repository: repository,
        tableRepository: tableRepository ?? _FakeTableRepository(tables),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> pumpDetailsPage(
  WidgetTester tester,
  StaffReservationRepository repository, {
  StaffReservationModel? reservation,
  String tableLabel = '12 · Window',
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: StaffReservationDetailsPage(
        reservation: reservation ?? buildStaffReservationModel(),
        tableLabel: tableLabel,
        repository: repository,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Every string rendered anywhere in the tree, joined, for leak checks.
String renderedText(WidgetTester tester) {
  final buffer = StringBuffer();

  void visit(Element element) {
    final widget = element.widget;
    if (widget is Text) {
      buffer.write(widget.data);
      buffer.write(' ');
    }

    element.visitChildren(visit);
  }

  visit(tester.element(find.byType(Scaffold).first));
  return buffer.toString();
}

void main() {
  final today = () {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }();

  group('BookingsPage', () {
    testWidgets('loads the selected day through the repository', (tester) async {
      final repository = _FakeStaffReservationRepository(
        responses: [
          [buildStaffReservationModel()],
        ],
      );

      await pumpBookingsPage(
        tester,
        repository,
        tables: [buildTable()],
        branchId: centerBranch,
      );

      expect(repository.listCalls, 1);
      expect(repository.listArguments.single.date, today);
      expect(repository.listArguments.single.branchId, centerBranch);
      expect(find.text('19:00'), findsOneWidget);
      expect(find.text('Mon, 5 Oct 2026 · 12 · Window'), findsOneWidget);
      expect(find.text('Askar · 2 guests'), findsOneWidget);
      expect(find.text('Confirmed'), findsOneWidget);
      expect(find.text('1 reservation'), findsOneWidget);
    });

    testWidgets('shows the table, guest count and status for each row', (
      tester,
    ) async {
      final repository = _FakeStaffReservationRepository(
        responses: [
          [
            buildStaffReservationModel(
              reservedDate: DateTime(2026, 10, 6),
              reservedTime: (hour: 13, minute: 30),
              guestName: 'Baktygul',
              guestCount: 3,
            ),
          ],
        ],
      );

      await pumpBookingsPage(tester, repository, tables: [buildTable()]);

      expect(find.text('13:30'), findsOneWidget);
      expect(find.text('Tue, 6 Oct 2026 · 12 · Window'), findsOneWidget);
      expect(find.text('Baktygul · 3 guests'), findsOneWidget);
      expect(find.text('Confirmed'), findsOneWidget);
    });

    testWidgets('shows a loading state until the answer arrives', (
      tester,
    ) async {
      final repository = _PendingStaffReservationRepository();

      await tester.pumpWidget(
        MaterialApp(
          home: BookingsPage(
            restaurantId: restaurantA,
            repository: repository,
            tableRepository: _FakeTableRepository(),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Loading reservations...'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byKey(const Key('bookingsList')), findsNothing);

      repository.answer([buildStaffReservationModel()]);
      await tester.pumpAndSettle();

      expect(find.text('Loading reservations...'), findsNothing);
      expect(find.byKey(const Key('bookingsList')), findsOneWidget);
    });

    testWidgets('shows an empty state when the day has no reservations', (
      tester,
    ) async {
      final repository = _FakeStaffReservationRepository();

      await pumpBookingsPage(tester, repository);

      expect(find.byKey(const Key('bookingsEmptyState')), findsOneWidget);
      expect(find.text('No reservations for this day'), findsOneWidget);
      expect(find.byKey(const Key('bookingsList')), findsNothing);
      // The day is still changeable and the read can be repeated.
      expect(find.byKey(const Key('bookingsDateButton')), findsOneWidget);
      expect(
        find.byKey(const Key('bookingsEmptyRefreshButton')),
        findsOneWidget,
      );
    });

    testWidgets('shows a friendly error state and can retry', (tester) async {
      final repository = _FakeStaffReservationRepository(
        listError: reservationPostgrestError(
          '42501',
          message: 'staff_reservation_access_denied',
        ),
      );

      await pumpBookingsPage(tester, repository);

      expect(
        find.text('You do not have permission to view these reservations.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('staff_reservation_access_denied'),
        findsNothing,
        reason: "the database's own message is never shown",
      );

      repository.listError = null;
      repository.responses = [
        [buildStaffReservationModel()],
      ];

      await tester.tap(find.byKey(const Key('bookingsRetryButton')));
      await tester.pumpAndSettle();

      expect(repository.listCalls, 2);
      expect(find.byKey(const Key('bookingsList')), findsOneWidget);
    });

    testWidgets('an ended session is reported as a sign-in problem', (
      tester,
    ) async {
      final repository = _FakeStaffReservationRepository(
        listError: reservationPostgrestError(
          '28000',
          message: 'Authentication is required to read restaurant reservations.',
        ),
      );

      await pumpBookingsPage(tester, repository);

      expect(
        find.text('Your session has ended. Please sign in again.'),
        findsOneWidget,
      );
    });

    testWidgets('pull to refresh re-reads the day', (tester) async {
      final repository = _FakeStaffReservationRepository(
        responses: [
          [buildStaffReservationModel(id: 'r1')],
          [
            buildStaffReservationModel(
              id: 'r2',
              reservedTime: (hour: 20, minute: 15),
            ),
          ],
        ],
      );

      await pumpBookingsPage(tester, repository, tables: [buildTable()]);

      expect(find.text('19:00'), findsOneWidget);

      await tester.fling(
        find.byKey(const Key('bookingsList')),
        const Offset(0, 400),
        1000,
      );
      await tester.pumpAndSettle();

      expect(repository.listCalls, 2);
      expect(find.text('19:00'), findsNothing);
      expect(find.text('20:15'), findsOneWidget);
    });

    testWidgets('changing the day re-reads that day', (tester) async {
      final repository = _FakeStaffReservationRepository(
        responses: [
          [buildStaffReservationModel()],
          [
            buildStaffReservationModel(
              reservedDate: DateTime(2026, 10, 6),
              reservedTime: (hour: 13, minute: 30),
            ),
          ],
        ],
      );

      await pumpBookingsPage(tester, repository, tables: [buildTable()]);

      expect(repository.listArguments.single.date, today);

      await tester.tap(find.byKey(const Key('bookingsNextDay')));
      await tester.pumpAndSettle();

      expect(repository.listCalls, 2);
      expect(
        repository.listArguments.last.date,
        DateTime(today.year, today.month, today.day + 1),
      );
      expect(find.text('13:30'), findsOneWidget);
    });

    testWidgets('falls back to a plain table label, never a raw id', (
      tester,
    ) async {
      // No tables served: the id in the payload must not be rendered instead.
      final repository = _FakeStaffReservationRepository(
        responses: [
          [buildStaffReservationModel()],
        ],
      );

      await pumpBookingsPage(tester, repository);

      expect(find.text('Mon, 5 Oct 2026 · Table'), findsOneWidget);
      expect(find.textContaining(reservationTableId), findsNothing);
    });

    testWidgets('a reservation with no table says so', (tester) async {
      final repository = _FakeStaffReservationRepository(
        responses: [
          [buildStaffReservationModel(tableId: null)],
        ],
      );

      await pumpBookingsPage(tester, repository);

      expect(find.text('Mon, 5 Oct 2026 · No table'), findsOneWidget);
    });

    testWidgets('a confirmed reservation offers a cancellation', (tester) async {
      final repository = _FakeStaffReservationRepository(
        responses: [
          [buildStaffReservationModel()],
        ],
      );

      await pumpBookingsPage(tester, repository, tables: [buildTable()]);

      expect(
        find.byKey(Key('bookingCancel_$reservationId')),
        findsOneWidget,
      );
    });

    testWidgets('a cancelled reservation offers no cancellation', (
      tester,
    ) async {
      final repository = _FakeStaffReservationRepository(
        responses: [
          [buildStaffReservationModel(status: ReservationStatus.cancelled)],
        ],
      );

      await pumpBookingsPage(tester, repository, tables: [buildTable()]);

      expect(find.text('Cancelled'), findsOneWidget);
      expect(find.byKey(Key('bookingCancel_$reservationId')), findsNothing);
    });

    testWidgets('cancels only after the staff member confirms', (tester) async {
      final repository = _FakeStaffReservationRepository(
        responses: [
          [buildStaffReservationModel()],
        ],
      );

      await pumpBookingsPage(tester, repository, tables: [buildTable()]);

      await tester.tap(find.byKey(Key('bookingCancel_$reservationId')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('cancelBookingDialog')), findsOneWidget);
      expect(repository.statusCalls, isEmpty);

      await tester.tap(find.text('Keep it'));
      await tester.pumpAndSettle();

      expect(repository.statusCalls, isEmpty);
      expect(
        find.byKey(Key('bookingCancel_$reservationId')),
        findsOneWidget,
      );
    });

    testWidgets('a confirmed cancellation refreshes the list', (tester) async {
      final repository = _FakeStaffReservationRepository(
        responses: [
          [buildStaffReservationModel()],
          [buildStaffReservationModel(status: ReservationStatus.cancelled)],
        ],
      );

      await pumpBookingsPage(tester, repository, tables: [buildTable()]);

      await tester.tap(find.byKey(Key('bookingCancel_$reservationId')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirmCancelBookingButton')));
      await tester.pumpAndSettle();

      expect(repository.statusCalls, [
        (reservationId: reservationId, status: ReservationStatus.cancelled),
      ]);
      expect(repository.listCalls, 2);
      expect(find.text('Cancelled'), findsOneWidget);
      expect(find.byKey(Key('bookingCancel_$reservationId')), findsNothing);
      expect(
        find.text('Reservation cancelled. The table is free again.'),
        findsOneWidget,
      );
    });

    testWidgets('a refused cancellation shows the safe reason', (tester) async {
      final repository = _FakeStaffReservationRepository(
        responses: [
          [buildStaffReservationModel()],
        ],
        statusError: reservationPostgrestError(
          '42501',
          message: 'staff_reservation_access_denied',
        ),
      );

      await pumpBookingsPage(tester, repository, tables: [buildTable()]);

      await tester.tap(find.byKey(Key('bookingCancel_$reservationId')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirmCancelBookingButton')));
      await tester.pumpAndSettle();

      expect(
        find.text('You do not have permission to change this reservation.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('staff_reservation_access_denied'),
        findsNothing,
      );
      // The list is re-read after a refusal: the database decides the status.
      expect(repository.listCalls, 2);
      expect(find.text('Confirmed'), findsOneWidget);
    });

    testWidgets('opens the details of the reservation that was tapped', (
      tester,
    ) async {
      final repository = _FakeStaffReservationRepository(
        responses: [
          [buildStaffReservationModel()],
        ],
      );

      await pumpBookingsPage(tester, repository, tables: [buildTable()]);

      await tester.tap(find.byKey(Key('bookingCard_$reservationId')));
      await tester.pumpAndSettle();

      expect(find.byType(StaffReservationDetailsPage), findsOneWidget);
      expect(find.text('12 · Window'), findsOneWidget);
      expect(find.text('Askar'), findsOneWidget);
    });

    testWidgets('a payload carrying a guest token shows nothing of it', (
      tester,
    ) async {
      // Parsed with the real parser, so a payload with a credential in it goes
      // through the same code the app runs rather than a hand-built model.
      final payload = buildStaffReservationsJson()
        ..['access_token'] = guestAccessToken;
      ((payload['reservations'] as List).first as Map<String, dynamic>)
        ..['access_token'] = guestAccessToken
        ..['reservation_access'] = [
          {'id': 'access-1', 'token_hash': 'e3b0c44298fc1c14'},
        ];

      final reservations = tryParseStaffReservations(
        jsonDecode(encodeReservationRpcResult(payload)),
        restaurantId: restaurantA,
      );

      final repository = _FakeStaffReservationRepository(
        responses: [reservations],
      );

      await pumpBookingsPage(tester, repository, tables: [buildTable()]);

      expect(find.text('19:00'), findsOneWidget);
      expect(renderedText(tester), isNot(contains(guestAccessToken)));
      expect(find.textContaining(guestAccessToken), findsNothing);

      await tester.tap(find.byKey(Key('bookingCard_$reservationId')));
      await tester.pumpAndSettle();

      expect(find.byType(StaffReservationDetailsPage), findsOneWidget);
      expect(renderedText(tester), isNot(contains(guestAccessToken)));
      expect(find.textContaining(guestAccessToken), findsNothing);
    });
  });

  group('StaffReservationDetailsPage', () {
    testWidgets('shows the booking, the party and when it was made', (
      tester,
    ) async {
      await pumpDetailsPage(tester, _FakeStaffReservationRepository());

      expect(find.text('Mon, 5 Oct 2026'), findsOneWidget);
      expect(find.text('19:00'), findsOneWidget);
      expect(find.text('12 · Window'), findsOneWidget);
      expect(find.text('Askar'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('Confirmed'), findsOneWidget);
      expect(
        find.text(
          formatOrderPlacedAt(DateTime.parse(reservationCreatedAt)),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a confirmed reservation can be cancelled', (tester) async {
      final repository = _FakeStaffReservationRepository();

      await pumpDetailsPage(tester, repository);

      expect(find.byKey(const Key('bookingDetailsCancel')), findsOneWidget);

      await tester.tap(find.byKey(const Key('bookingDetailsCancel')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('cancelBookingDialog')), findsOneWidget);

      await tester.tap(find.byKey(const Key('confirmCancelBookingButton')));
      await tester.pumpAndSettle();

      expect(repository.statusCalls, [
        (reservationId: reservationId, status: ReservationStatus.cancelled),
      ]);
      expect(find.text('Cancelled'), findsOneWidget);
      expect(find.byKey(const Key('bookingDetailsNoActions')), findsOneWidget);
      expect(find.byKey(const Key('bookingDetailsCancel')), findsNothing);
    });

    testWidgets('a cancelled reservation offers no cancellation', (
      tester,
    ) async {
      await pumpDetailsPage(
        tester,
        _FakeStaffReservationRepository(),
        reservation: buildStaffReservationModel(
          status: ReservationStatus.cancelled,
        ),
      );

      expect(find.byKey(const Key('bookingDetailsCancel')), findsNothing);
      expect(find.byKey(const Key('bookingDetailsNoActions')), findsOneWidget);
      expect(
        find.text('A cancelled reservation cannot be restored.'),
        findsOneWidget,
      );
    });

    testWidgets('a refused cancellation changes nothing on screen', (
      tester,
    ) async {
      final repository = _FakeStaffReservationRepository(
        statusError: reservationPostgrestError(
          '42501',
          message: 'staff_reservation_access_denied',
        ),
      );

      await pumpDetailsPage(tester, repository);

      await tester.tap(find.byKey(const Key('bookingDetailsCancel')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirmCancelBookingButton')));
      await tester.pumpAndSettle();

      expect(
        find.text('You do not have permission to change this reservation.'),
        findsOneWidget,
      );
      expect(find.text('Confirmed'), findsOneWidget);
      expect(find.byKey(const Key('bookingDetailsCancel')), findsOneWidget);
    });
  });
}
