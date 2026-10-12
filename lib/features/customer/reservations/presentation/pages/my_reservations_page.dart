import 'package:flutter/material.dart';
import 'package:menukg_flutter/features/customer/reservations/data/models/reservation_model.dart';
import 'package:menukg_flutter/features/customer/reservations/data/repositories/reservation_repository.dart';
import 'package:menukg_flutter/features/customer/reservations/data/reservation_access_store.dart';
import 'package:menukg_flutter/features/customer/reservations/presentation/reservation_error_message.dart';

/// The guest's own reservations, read back with the access token on this device.
///
/// There is no account to sign in with, so this page is honest about what it is:
/// the reservations made on this device, and nothing else. A guest who changes
/// phone, or clears app data, sees an empty list, because the token is the only
/// credential and it is gone. Showing that plainly is better than a list that
/// quietly hides reservations the guest remembers making.
class MyReservationsPage extends StatefulWidget {
  const MyReservationsPage({super.key, this.repository, this.accessStore});

  final ReservationRepository? repository;
  final ReservationAccessStore? accessStore;

  @override
  State<MyReservationsPage> createState() => _MyReservationsPageState();
}

class _MyReservationsPageState extends State<MyReservationsPage> {
  late ReservationRepository _repository =
      widget.repository ?? const ReservationRepository();
  late ReservationAccessStore _accessStore =
      widget.accessStore ?? const DeviceReservationAccessStore();

  /// `null` while loading, a list once loaded.
  List<ReservationModel>? _reservations;
  String? _errorMessage;
  bool _isLoading = true;

  @override
  void didUpdateWidget(MyReservationsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.repository, widget.repository)) {
      _repository = widget.repository ?? const ReservationRepository();
    }
    if (!identical(oldWidget.accessStore, widget.accessStore)) {
      _accessStore = widget.accessStore ?? const DeviceReservationAccessStore();
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final token = await _accessStore.readToken();
      final reservations = await _repository.getMyReservations(token);
      if (!mounted) {
        return;
      }
      setState(() {
        _reservations = reservations;
        _isLoading = false;
      });
    } catch (error) {
      debugPrint('Loading reservations failed: $error');
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
        _errorMessage = reservationListErrorMessage(error);
      });
    }
  }

  Future<void> _cancel(ReservationModel reservation) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('cancelReservationDialog'),
        title: const Text('Cancel reservation?'),
        content: Text(
          'Your table on ${reservation.whenLabel} will be released.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            key: const Key('confirmCancelReservationButton'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Cancel reservation'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    try {
      final token = await _accessStore.readToken();
      if (token == null) {
        return;
      }
      final cancelled = await _repository.cancelReservation(
        accessToken: token,
        reservationId: reservation.id,
      );
      if (!mounted) {
        return;
      }
      if (cancelled) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(reservationCancelledMessage)),
        );
      }
      // Reloads either way: the database is the source of truth, so a slot that
      // was taken by someone else in the meantime also shows up here.
      await _load();
    } catch (error) {
      debugPrint('Cancelling a reservation failed: $error');
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(reservationErrorMessage(error))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My reservations'),
        actions: [
          IconButton(
            key: const Key('reloadReservationsButton'),
            onPressed: _isLoading ? null : _load,
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(child: _buildBody(context)),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_isLoading && _reservations == null) {
      return const Center(
        child: CircularProgressIndicator(key: Key('reservationsLoading')),
      );
    }

    if (_errorMessage != null && _reservations == null) {
      return _MessagePane(
        icon: Icons.cloud_off_outlined,
        message: _errorMessage!,
        actionLabel: 'Try again',
        onAction: _load,
        actionKey: const Key('retryReservationsButton'),
      );
    }

    final reservations = _reservations ?? const [];
    if (reservations.isEmpty) {
      return const _MessagePane(
        key: Key('reservationsEmptyState'),
        icon: Icons.event_busy_outlined,
        message: 'No reservations on this device yet.\n'
            'Open a table QR code to make one.',
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: reservations.length,
      separatorBuilder: (context, index) => const SizedBox(height: 12),
      itemBuilder: (context, index) => _ReservationCard(
        reservation: reservations[index],
        onCancel: reservations[index].isCancelled ? null : _cancel,
      ),
    );
  }
}

class _ReservationCard extends StatelessWidget {
  const _ReservationCard({required this.reservation, this.onCancel});

  final ReservationModel reservation;
  final ValueChanged<ReservationModel>? onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isCancelled = reservation.isCancelled;

    return Card(
      key: Key('reservationCard_${reservation.id}'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              reservation.restaurantName,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 2),
            Text(
              reservation.branchName,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              reservation.whenLabel,
              key: Key('reservationWhen_${reservation.id}'),
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              '${reservation.partyLabel} · ${reservation.table.label}',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            if (isCancelled)
              Text(
                reservationCancelledMessage,
                key: Key('reservationCancelled_${reservation.id}'),
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.error,
                ),
              )
            else
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  key: Key('cancelReservation_${reservation.id}'),
                  onPressed: () => onCancel!(reservation),
                  icon: const Icon(Icons.close),
                  label: const Text('Cancel'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MessagePane extends StatelessWidget {
  const _MessagePane({
    super.key,
    required this.icon,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.actionKey,
  });

  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Key? actionKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
            if (actionLabel != null) ...[
              const SizedBox(height: 16),
              FilledButton(
                key: actionKey,
                onPressed: onAction,
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
