import 'package:flutter/material.dart';
import 'package:menukg_flutter/features/customer/orders/data/models/order_model.dart';
import 'package:menukg_flutter/features/customer/reservations/data/models/reservation_model.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/models/staff_reservation_model.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/repositories/staff_reservation_repository.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/staff_reservation_error_message.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/widgets/staff_reservation_status_chip.dart';

/// One reservation, in full, for the staff member who has to act on it.
///
/// Read-only apart from the cancellation. There is no editing of any kind here:
/// no date, time, party size or table to change, because
/// `staff_set_reservation_status` changes a status and nothing else and the
/// database offers no way to rewrite a booking. A screen that offered an editor
/// would be offering something the backend cannot carry out.
///
/// The only move this phase defines is `CONFIRMED -> CANCELLED`, so a confirmed
/// reservation offers one action and a cancelled one offers none. Whether the
/// caller's role may cancel is not decided here: the database re-checks the
/// membership and the role on every call, so an action refused by the backend is
/// reported through [staffReservationStatusErrorMessage] rather than hidden by a
/// second copy of the role matrix on this screen.
///
/// The table is shown as the label the list resolved from `tables`, never as the
/// raw id, and the guest's access token is not part of the model or the payload
/// and so cannot be shown.
class StaffReservationDetailsPage extends StatefulWidget {
  const StaffReservationDetailsPage({
    super.key,
    required this.reservation,
    required this.tableLabel,
    this.repository = const StaffReservationRepository(),
  });

  /// The reservation to show, as the bookings list already holds it.
  final StaffReservationModel reservation;

  /// The table as the bookings list resolved it, for example `12 · Window`, or
  /// `No table` when the reservation names none.
  final String tableLabel;

  final StaffReservationRepository repository;

  @override
  State<StaffReservationDetailsPage> createState() =>
      _StaffReservationDetailsPageState();
}

class _StaffReservationDetailsPageState
    extends State<StaffReservationDetailsPage> {
  late StaffReservationModel _reservation = widget.reservation;
  bool _isChangingStatus = false;

  Future<void> _cancel() async {
    final confirmed = await _confirmCancellation();
    if (confirmed != true) {
      return;
    }

    setState(() => _isChangingStatus = true);

    try {
      final update = await widget.repository.setReservationStatus(
        reservationId: _reservation.id,
        status: ReservationStatus.cancelled,
      );

      if (!mounted) {
        return;
      }

      if (update == null) {
        // The database accepted the call but the answer is not a status change
        // this client can read, so nothing is claimed: the reservation keeps the
        // status it had.
        _showMessage(
          'We could not confirm that change. Pull down to refresh the list.',
        );
        return;
      }

      setState(() {
        _reservation = _reservation.withStatus(
          update.status,
          updatedAt: update.updatedAt,
        );
      });
      _showMessage(_reservationCancelledMessage);
    } catch (error, stackTrace) {
      debugPrint('Cancelling a reservation failed: $error\n$stackTrace');
      if (!mounted) {
        return;
      }
      // The wording tells a refused cancellation and an ended session apart
      // without exposing anything from the database's own message.
      _showMessage(staffReservationStatusErrorMessage(error));
    } finally {
      if (mounted) {
        setState(() => _isChangingStatus = false);
      }
    }
  }

  Future<bool?> _confirmCancellation() {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('cancelBookingDialog'),
        title: const Text('Cancel this reservation?'),
        content: Text(
          'The table booked by ${_reservation.guestName} on '
          '${_reservation.whenLabel} is released and becomes available to other '
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
    final theme = Theme.of(context);
    final isCancelled = _reservation.isCancelled;

    return Scaffold(
      key: const Key('staffReservationDetails'),
      appBar: AppBar(
        title: const Text('Reservation'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: StaffReservationStatusChip(status: _reservation.status),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _DetailRow(
                    icon: Icons.event_outlined,
                    label: 'Date',
                    value: formatReservationDay(_reservation.reservedDate),
                  ),
                  _DetailRow(
                    icon: Icons.schedule_outlined,
                    label: 'Time',
                    value: formatReservationClock(
                      hour: _reservation.reservedTime.hour,
                      minute: _reservation.reservedTime.minute,
                    ),
                  ),
                  _DetailRow(
                    icon: Icons.table_restaurant_outlined,
                    label: 'Table',
                    value: widget.tableLabel,
                  ),
                  _DetailRow(
                    icon: Icons.person_outline,
                    label: 'Guest',
                    value: _reservation.guestName,
                  ),
                  _DetailRow(
                    icon: Icons.groups_outlined,
                    label: 'Guests',
                    value: '${_reservation.guestCount}',
                  ),
                  _DetailRow(
                    icon: Icons.history_outlined,
                    label: 'Booked',
                    value: formatOrderPlacedAt(_reservation.createdAt),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text('Cancellation', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            isCancelled
                ? 'A cancelled reservation cannot be restored.'
                : 'Cancelling releases the table so other guests can book it.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          if (isCancelled)
            Semantics(
              liveRegion: true,
              child: Text(
                'This reservation has been cancelled.',
                key: const Key('bookingDetailsNoActions'),
                style: theme.textTheme.bodyMedium,
              ),
            )
          else
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const Key('bookingDetailsCancel'),
                onPressed: _isChangingStatus ? null : _cancel,
                icon: _isChangingStatus
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.cancel_outlined),
                label: const Text('Cancel reservation'),
              ),
            ),
        ],
      ),
    );
  }
}

/// Shown when a confirmed reservation is cancelled: the table is free again.
const String _reservationCancelledMessage =
    'Reservation cancelled. The table is free again.';

/// A labelled value, with the icon that names it.
///
/// The status is not repeated here: it is the chip in the app bar, which is
/// where the eye goes first, and a screen that says the same word twice in two
/// weights reads as two different facts.
class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyLarge,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
