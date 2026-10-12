import 'package:flutter/material.dart';
import 'package:menukg_flutter/features/customer/reservations/data/models/reservation_model.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/models/staff_reservation_model.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/repositories/staff_reservation_repository.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/repositories/table_repository.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/pages/staff_reservation_details_page.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/staff_reservation_error_message.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/widgets/staff_reservation_status_chip.dart';

/// The staff bookings board: one day of one restaurant's reservations.
///
/// Every reservation here comes from `staff_list_reservations` through
/// [StaffReservationRepository], and the one status change goes through
/// `staff_set_reservation_status`. This page opens no table directly, because the
/// reservations tables carry no grant for any client role: a booking could not be
/// read this way even if this file asked for it.
///
/// The page is a schedule rather than a feed, so it is filtered to one day and
/// reads oldest booking first — the order the database already returns. The day
/// defaults to today and can be stepped a day at a time or picked, and every
/// change re-reads through the repository. There is no branch picker, no search
/// and no grouping by status: they belong with a larger list, and a filter that
/// hides a booking is a filter that can hide a guest with a table.
///
/// The table is shown as a label resolved from `tables`, never as the raw id in
/// the reservation payload. A label that cannot be resolved falls back to a plain
/// `Table`, and a reservation with no table says `No table`, so an id is never
/// rendered. Best-effort resolution is deliberate: a failure to read table labels
/// must not hide the bookings themselves.
class BookingsPage extends StatefulWidget {
  const BookingsPage({
    super.key,
    required this.restaurantId,
    this.branchId,
    this.repository = const StaffReservationRepository(),
    this.tableRepository = const TableRepository(),
  });

  /// The restaurant whose reservations are worked on this page.
  final String restaurantId;

  /// The active branch, when the dashboard has one. Bookings of a restaurant
  /// whose branch is not known are still read, because the read is scoped by
  /// restaurant and the database filters a branch that is named.
  final String? branchId;

  final StaffReservationRepository repository;

  /// Resolves a reservation's table id to the label staff read at the table.
  final TableRepository tableRepository;

  @override
  State<BookingsPage> createState() => _BookingsPageState();
}

class _BookingsPageState extends State<BookingsPage> {
  /// The selected day, as a local date with no time of day.
  DateTime _date = _today();

  List<StaffReservationModel> _reservations = const [];

  /// Table id to display label, resolved from `tables`.
  Map<String, String> _tableLabels = const {};

  bool _isLoading = true;
  String? _errorMessage;

  /// Reservations with a cancellation in flight, so two taps cannot race one.
  final Set<String> _busyReservationIds = <String>{};

  static DateTime _today() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Loads the selected day's reservations and the table labels they need.
  ///
  /// [showLoading] is false for a reload behind an existing list, so a pull to
  /// refresh or a day change does not replace a usable list with a spinner.
  Future<void> _load({bool showLoading = true}) async {
    if (showLoading) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }

    try {
      final reservations = await widget.repository.getReservations(
        restaurantId: widget.restaurantId,
        branchId: widget.branchId,
        date: _date,
      );
      final labels = await _loadTableLabels();
      if (!mounted) {
        return;
      }
      setState(() {
        _reservations = reservations;
        _tableLabels = labels;
        _isLoading = false;
        _errorMessage = null;
      });
    } catch (error, stackTrace) {
      debugPrint('Loading staff reservations failed: $error\n$stackTrace');
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
        _errorMessage = staffReservationListErrorMessage(error);
      });
    }
  }

  /// Builds the table id-to-label map, or an empty one if the labels cannot be
  /// read. A booking is never hidden because its table label is missing.
  Future<Map<String, String>> _loadTableLabels() async {
    try {
      final tables = await widget.tableRepository.getTables(
        widget.restaurantId,
        branchId: widget.branchId,
      );
      return {for (final table in tables) table.id: table.displayName};
    } catch (error, stackTrace) {
      debugPrint('Loading table labels for bookings failed: $error\n$stackTrace');
      return const {};
    }
  }

  Future<void> _refresh() => _load(showLoading: false);

  /// The label shown for a reservation's table, never a raw id.
  String _tableLabelFor(String? tableId) {
    if (tableId == null || tableId.trim().isEmpty) {
      return 'No table';
    }
    return _tableLabels[tableId] ?? 'Table';
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(now.year - 2, now.month, now.day),
      lastDate: DateTime(now.year + 2, now.month, now.day),
    );
    if (picked != null && mounted) {
      await _changeDate(picked);
    }
  }

  Future<void> _changeDate(DateTime date) async {
    setState(() => _date = DateTime(date.year, date.month, date.day));
    await _load();
  }

  Future<void> _openReservation(StaffReservationModel reservation) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => StaffReservationDetailsPage(
          reservation: reservation,
          tableLabel: _tableLabelFor(reservation.tableId),
          repository: widget.repository,
        ),
      ),
    );

    // The details page cancelled this reservation, or refused to, and another
    // device may have changed something since this list was read. Re-reading is
    // the only way to be sure the list on screen is the database's answer.
    await _load(showLoading: false);
  }

  /// Cancels one reservation after the staff member confirms, then re-reads.
  ///
  /// The success or refusal wording comes from the database's answer:
  /// [staffReservationStatusErrorMessage] maps a refusal, and a cancelled
  /// reservation is confirmed for the slot it releases. Whether the caller's role
  /// may cancel is not decided here — the database re-checks it and refuses with
  /// the same safe message.
  Future<void> _cancel(StaffReservationModel reservation) async {
    final confirmed = await _confirmCancellation(reservation);
    if (confirmed != true) {
      return;
    }

    setState(() => _busyReservationIds.add(reservation.id));

    try {
      final update = await widget.repository.setReservationStatus(
        reservationId: reservation.id,
        status: ReservationStatus.cancelled,
      );

      if (!mounted) {
        return;
      }

      if (update == null) {
        _showMessage(
          'We could not confirm that change. Pull down to refresh the list.',
        );
        await _load(showLoading: false);
        return;
      }

      _showMessage('Reservation cancelled. The table is free again.');
    } catch (error, stackTrace) {
      debugPrint('Cancelling a reservation failed: $error\n$stackTrace');
      if (!mounted) {
        return;
      }
      _showMessage(staffReservationStatusErrorMessage(error));
    } finally {
      if (mounted) {
        setState(() => _busyReservationIds.remove(reservation.id));
      }
    }

    await _load(showLoading: false);
  }

  Future<bool?> _confirmCancellation(StaffReservationModel reservation) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('cancelBookingDialog'),
        title: const Text('Cancel this reservation?'),
        content: Text(
          'The table booked by ${reservation.guestName} on '
          '${reservation.whenLabel} is released and becomes available to other '
          'guests. A cancelled reservation cannot be restored.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            key: const Key('confirmCancelBookingButton'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Cancel reservation'),
          ),
        ],
      ),
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bookings'),
        actions: [
          IconButton(
            key: const Key('bookingsRefreshButton'),
            onPressed: _isLoading ? null : _refresh,
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _BookingsDateBar(
              date: _date,
              isToday: _date == _today(),
              onPrevious: () =>
                  _changeDate(DateTime(_date.year, _date.month, _date.day - 1)),
              onNext: () =>
                  _changeDate(DateTime(_date.year, _date.month, _date.day + 1)),
              onPick: _pickDate,
              onToday: () => _changeDate(_today()),
            ),
            Expanded(child: _buildBody(context)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_isLoading) {
      return const _BookingsLoadingState();
    }

    if (_errorMessage case final message?) {
      return _BookingsErrorState(message: message, onRetry: _load);
    }

    if (_reservations.isEmpty) {
      return _BookingsEmptyState(onRefresh: _refresh, onPickDate: _pickDate);
    }

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.builder(
        key: const Key('bookingsList'),
        // Always scrollable, so the pull gesture is reachable even for a short day.
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        itemCount: _reservations.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return _BookingsCount(count: _reservations.length);
          }

          final reservation = _reservations[index - 1];
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _ReservationCard(
              reservation: reservation,
              tableLabel: _tableLabelFor(reservation.tableId),
              isBusy: _busyReservationIds.contains(reservation.id),
              onTap: () => _openReservation(reservation),
              onCancel: reservation.isCancelled
                  ? null
                  : () => _cancel(reservation),
            ),
          );
        },
      ),
    );
  }
}

/// The day selector: step a day back or forward, or pick one.
///
/// A booking list is worked a day at a time, so the day is the page's one piece
/// of scope and it is always on screen rather than hidden behind a filter sheet.
class _BookingsDateBar extends StatelessWidget {
  const _BookingsDateBar({
    required this.date,
    required this.isToday,
    required this.onPrevious,
    required this.onNext,
    required this.onPick,
    required this.onToday,
  });

  final DateTime date;
  final bool isToday;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onPick;
  final VoidCallback onToday;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            children: [
              IconButton(
                key: const Key('bookingsPreviousDay'),
                onPressed: onPrevious,
                tooltip: 'Previous day',
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: InkWell(
                  key: const Key('bookingsDateButton'),
                  onTap: onPick,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      children: [
                        Text(
                          formatReservationDay(date),
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleMedium,
                        ),
                        Text(
                          'Tap to choose a day',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              IconButton(
                key: const Key('bookingsNextDay'),
                onPressed: onNext,
                tooltip: 'Next day',
                icon: const Icon(Icons.chevron_right),
              ),
              if (!isToday)
                TextButton(
                  key: const Key('bookingsTodayButton'),
                  onPressed: onToday,
                  child: const Text('Today'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The list heading: how many reservations the selected day holds.
class _BookingsCount extends StatelessWidget {
  const _BookingsCount({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final countLabel = count == 1 ? '1 reservation' : '$count reservations';

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Reservations',
              style: theme.textTheme.headlineMedium,
            ),
          ),
          Text(
            countLabel,
            key: const Key('bookingsCount'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// One reservation in the list.
class _ReservationCard extends StatelessWidget {
  const _ReservationCard({
    required this.reservation,
    required this.tableLabel,
    required this.isBusy,
    required this.onTap,
    required this.onCancel,
  });

  final StaffReservationModel reservation;
  final String tableLabel;
  final bool isBusy;
  final VoidCallback onTap;

  /// The cancellation to offer, or `null` for a reservation that has none.
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final clock = formatReservationClock(
      hour: reservation.reservedTime.hour,
      minute: reservation.reservedTime.minute,
    );

    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        key: Key('bookingCard_${reservation.id}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // The time leads, because a booking is worked by when the
                        // guest arrives, not by who they are.
                        Text(
                          clock,
                          key: Key('bookingTime_${reservation.id}'),
                          style: theme.textTheme.titleLarge,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${formatReservationDay(reservation.reservedDate)} · '
                          '$tableLabel',
                          key: Key('bookingTable_${reservation.id}'),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          reservation.partyLabel,
                          key: Key('bookingParty_${reservation.id}'),
                          style: theme.textTheme.bodyLarge,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  StaffReservationStatusChip(status: reservation.status),
                ],
              ),
              if (onCancel != null) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    key: Key('bookingCancel_${reservation.id}'),
                    onPressed: isBusy ? null : onCancel,
                    icon: isBusy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.close, size: 18),
                    label: const Text('Cancel'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _BookingsLoadingState extends StatelessWidget {
  const _BookingsLoadingState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Loading reservations...'),
        ],
      ),
    );
  }
}

class _BookingsErrorState extends StatelessWidget {
  const _BookingsErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 48,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              message,
              key: const Key('bookingsErrorMessage'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('bookingsRetryButton'),
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}

class _BookingsEmptyState extends StatelessWidget {
  const _BookingsEmptyState({
    required this.onRefresh,
    required this.onPickDate,
  });

  final VoidCallback onRefresh;
  final VoidCallback onPickDate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.event_busy_outlined,
              size: 56,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              'No reservations for this day',
              key: const Key('bookingsEmptyState'),
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'Guests who book a table for the selected day will appear here.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              key: const Key('bookingsEmptyRefreshButton'),
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh),
              label: const Text('Check again'),
            ),
            const SizedBox(height: 8),
            TextButton(
              key: const Key('bookingsEmptyPickDateButton'),
              onPressed: onPickDate,
              child: const Text('Pick another day'),
            ),
          ],
        ),
      ),
    );
  }
}
