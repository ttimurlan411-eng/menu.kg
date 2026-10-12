import 'dart:async';

import 'package:flutter/material.dart';
import 'package:menukg_flutter/features/customer/orders/data/models/order_model.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/models/staff_order_model.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/repositories/staff_order_repository.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/staff_order_actions.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/staff_order_error_message.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/widgets/staff_order_status_chip.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The statuses the kitchen works on: an order waiting to be started and one being
/// made. Ready orders are the pass, and served and cancelled ones are done.
///
/// This is a presentation filter and nothing more. The read now uses
/// `staff_list_active_orders`, so every active order is guaranteed to be in the
/// response however much history is behind it; this page then chooses which of the
/// active states a cook acts on. The database still decides what may be moved, and
/// this set decides nothing about who may read.
const Set<OrderStatus> kitchenVisibleStatuses = {
  OrderStatus.accepted,
  OrderStatus.preparing,
};

/// The role whose moves the kitchen screen offers.
///
/// The page is the kitchen's screen, so it always asks
/// [staffOrderActionsFor] as `KITCHEN`. The database re-derives the caller's real
/// role on every call, so this constant decides only which buttons appear, never
/// what is permitted.
const String kitchenRole = 'KITCHEN';

/// How often the elapsed-time text is redrawn, and nothing else.
///
/// A minute is what the text is written in, so half of one keeps a ticket from
/// reading a whole minute behind for long. The tick only recomputes a local clock:
/// it never reads the database, so a kitchen screen that sits open all service makes
/// no more requests than the reads the staff member asked for.
const Duration kitchenElapsedTick = Duration(seconds: 30);

/// Formats how long an order has been waiting, for example `5 min` or `1 h 12 min`.
///
/// Whole minutes are dropped from the calculation rather than rounded up, so a ticket
/// never looks older than it is. Under a minute reads as `Just now` rather than `0 min`,
/// which is a clock reading rather than a statement about the order.
String formatKitchenElapsed(Duration elapsed) {
  final totalMinutes = elapsed.isNegative ? 0 : elapsed.inMinutes;
  if (totalMinutes < 1) {
    return 'Just now';
  }
  final hours = totalMinutes ~/ 60;
  final minutes = totalMinutes % 60;
  if (hours == 0) {
    return '$totalMinutes min';
  }
  if (minutes == 0) {
    return '$hours h';
  }
  return '$hours h $minutes min';
}

/// The kitchen's working list: the orders waiting to be cooked and being cooked.
///
/// Reads through the same [StaffOrderRepository] and `staff_list_active_orders` the
/// staff orders list uses, so there is no second read path and no kitchen-specific
/// query. What it adds is a point of view: only the two statuses a cook acts on,
/// oldest first, with how long each has been waiting, and only the moves
/// [staffOrderActionsFor] offers the kitchen role.
///
/// There is no realtime and no polling. Orders arrive by the initial read and by pull
/// to refresh, and the screen says so rather than pretending otherwise. A periodic
/// timer redraws the elapsed time from the device clock and performs no request.
///
/// The actions are the role's own, derived from the same lifecycle the database
/// enforces. A move refused by the backend is shown as the wording
/// [staffOrderStatusErrorMessage] builds, never as the database's own message.
class KitchenPage extends StatefulWidget {
  const KitchenPage({
    super.key,
    required this.restaurantId,
    this.branchId,
    this.repository = const StaffOrderRepository(),
    this.supabaseClient,
    this.enableRealtime = true,
  });

  /// The restaurant whose orders the kitchen works.
  final String restaurantId;

  /// The active branch, when the dashboard has one. A blank or missing branch reads
  /// the whole restaurant, exactly as on the staff orders list.
  final String? branchId;

  final StaffOrderRepository repository;

  final SupabaseClient? supabaseClient;
  final bool enableRealtime;

  SupabaseClient? get supabaseClientInstance => supabaseClient;

  @override
  State<KitchenPage> createState() => _KitchenPageState();
}

class _KitchenPageState extends State<KitchenPage> {
  List<StaffOrderModel> _orders = const [];
  bool _isLoading = true;
  String? _errorMessage;

  /// Orders with a status change in flight, so two taps cannot race one order.
  final Set<String> _busyOrderIds = <String>{};

  Timer? _elapsedTimer;

  /// The clock the elapsed text is drawn from, refreshed by the timer.
  DateTime _now = DateTime.now();

  RealtimeChannel? _realtimeChannel;

  /// Shown when the realtime channel cannot keep the list live, so the screen says
  /// so instead of silently going stale beside a ticket that moved.
  String? _realtimeStatusMessage;

  /// True while one read is running. Reads never overlap: requests that arrive
  /// during a read are queued in [_pendingReads] and coalesced into the next one.
  bool _refreshInFlight = false;

  /// Reads waiting for a turn. Each entry is one request and completes when the
  /// read that served it has finished.
  final List<({bool showLoading, Completer<void> done})> _pendingReads = [];

  /// The batch whose read is in flight, completed on dispose so a refresh left
  /// running is never awaited forever.
  List<({bool showLoading, Completer<void> done})>? _inFlightBatch;

  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _elapsedTimer = Timer.periodic(kitchenElapsedTick, _onElapsedTick);
    _loadOrders();
    if (widget.enableRealtime) {
      _setupRealtime();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _completeAll(List.of(_pendingReads));
    _pendingReads.clear();
    if (_inFlightBatch case final batch?) {
      _completeAll(batch);
      _inFlightBatch = null;
    }
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
    if (widget.enableRealtime) {
      _unsubscribeRealtime();
    }
    super.dispose();
  }

  /// Redraws the elapsed time. It reads no order and sends no request.
  void _onElapsedTick(Timer _) {
    if (!mounted) {
      return;
    }
    setState(() => _now = DateTime.now());
  }

  void _setupRealtime() {
    if (widget.restaurantId.trim().isEmpty) {
      return;
    }

    final client = widget.supabaseClientInstance ?? Supabase.instance.client;
    final channel = client.channel(
      'kitchen:order_change_events:${widget.restaurantId.trim()}',
    );

    channel.onPostgresChanges(
      event: PostgresChangeEvent.insert,
      schema: 'public',
      table: 'order_change_events',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'restaurant_id',
        value: widget.restaurantId.trim(),
      ),
      callback: _onRealtimeEvent,
    );

    channel.onPostgresChanges(
      event: PostgresChangeEvent.update,
      schema: 'public',
      table: 'order_change_events',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'restaurant_id',
        value: widget.restaurantId.trim(),
      ),
      callback: _onRealtimeEvent,
    );

    channel.subscribe(_onRealtimeSubscriptionStatus);
    _realtimeChannel = channel;
  }

  /// Reacts to the channel's own state so a screen that loses live updates says so
  /// instead of pretending it is still being fed. A reconnected channel clears it.
  void _onRealtimeSubscriptionStatus(
    RealtimeSubscribeStatus status,
    Object? _,
  ) {
    if (_disposed || !mounted) {
      return;
    }

    final next = switch (status) {
      RealtimeSubscribeStatus.subscribed => null,
      RealtimeSubscribeStatus.channelError ||
      RealtimeSubscribeStatus.timedOut ||
      RealtimeSubscribeStatus.closed =>
        'Live order updates are unavailable. Pull down to refresh the kitchen list.',
    };

    if (next == _realtimeStatusMessage) {
      return;
    }
    setState(() => _realtimeStatusMessage = next);
  }

  void _onRealtimeEvent(PostgresChangePayload payload) {
    if (!mounted) {
      return;
    }

    final newRecord = payload.newRecord;
    final record = newRecord;
    final eventBranchId = record['branch_id'] as String?;
    final currentBranch = widget.branchId?.trim();
    if (currentBranch != null && currentBranch.isNotEmpty) {
      if (eventBranchId == null || eventBranchId.trim() != currentBranch) {
        return;
      }
    }

    _triggerRefresh();
  }

  void _unsubscribeRealtime() async {
    final channel = _realtimeChannel;
    if (channel != null) {
      try {
        (widget.supabaseClientInstance ?? Supabase.instance.client)
            .removeChannel(channel);
      } catch (_) {}
      _realtimeChannel = null;
    }
  }

  void _triggerRefresh() {
    if (!mounted) {
      return;
    }
    unawaited(_loadOrders(showLoading: false));
  }

  /// Loads the list.
  ///
  /// [showLoading] is false for a reload behind an existing list, so a status
  /// change, a pull to refresh or a realtime event does not replace a usable list
  /// with a spinner: the list stays on screen while the next read runs.
  ///
  /// Reads never overlap. A request that arrives while a read is running waits in
  /// a queue and is folded into the next batch, so a burst of realtime events
  /// becomes one extra read rather than one per event. The returned future
  /// completes when the read that served this request has finished.
  Future<void> _loadOrders({bool showLoading = true}) {
    final done = Completer<void>();
    _pendingReads.add((showLoading: showLoading, done: done));
    unawaited(_drainReads());
    return done.future;
  }

  /// Serves the queued requests one batch at a time.
  ///
  /// While a read runs, further requests accumulate in [_pendingReads]; when it
  /// finishes, any that arrived are read once as a single follow-up. A request
  /// that asks for the spinner wins it for the whole batch.
  Future<void> _drainReads() async {
    if (_refreshInFlight) {
      return;
    }
    _refreshInFlight = true;
    try {
      while (_pendingReads.isNotEmpty) {
        final batch = List<({bool showLoading, Completer<void> done})>.of(
          _pendingReads,
        );
        _pendingReads.clear();

        if (!mounted) {
          _completeAll(batch);
          break;
        }

        _inFlightBatch = batch;
        final showLoading = batch.any((entry) => entry.showLoading);
        await _readOrders(showLoading: showLoading);
        _completeAll(batch);
        _inFlightBatch = null;
      }
    } finally {
      _refreshInFlight = false;
      if (_pendingReads.isNotEmpty) {
        if (mounted) {
          unawaited(_drainReads());
        } else {
          _completeAll(List.of(_pendingReads));
          _pendingReads.clear();
        }
      }
    }
  }

  void _completeAll(List<({bool showLoading, Completer<void> done})> batch) {
    for (final entry in batch) {
      if (!entry.done.isCompleted) {
        entry.done.complete();
      }
    }
  }

  /// One database read, shared by every request in a batch.
  Future<void> _readOrders({required bool showLoading}) async {
    if (showLoading) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }

    try {
      final orders = await widget.repository.getActiveOrders(
        restaurantId: widget.restaurantId,
        branchId: widget.branchId,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _orders = orders;
        _isLoading = false;
        _errorMessage = null;
      });
    } catch (error, stackTrace) {
      debugPrint('Loading kitchen orders failed: $error\n$stackTrace');
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
        _errorMessage = staffOrderListErrorMessage(error);
      });
    }
  }

  Future<void> _refresh() => _loadOrders(showLoading: false);

  /// Moves one order and keeps the list honest about what happened.
  ///
  /// A successful move is confirmed from the answer the database gave, and the list is
  /// re-read because a move out of the kitchen — preparing to ready — takes the order
  /// off this screen, and only the database is the authority on where it now is.
  Future<void> _changeStatus(StaffOrderModel order, OrderStatus target) async {
    setState(() => _busyOrderIds.add(order.id));

    try {
      final update = await widget.repository.setOrderStatus(
        orderId: order.id,
        status: target,
      );

      if (!mounted) {
        return;
      }

      if (update == null) {
        _showMessage(
          'We could not confirm that change. Pull down to refresh the kitchen list.',
        );
        await _loadOrders(showLoading: false);
        return;
      }

      _showMessage(
        'Order ${order.numberLabel} is now ${update.status.displayLabel.toLowerCase()}.',
      );
      await _loadOrders(showLoading: false);
    } catch (error, stackTrace) {
      debugPrint('Changing an order status failed: $error\n$stackTrace');
      if (!mounted) {
        return;
      }
      _showMessage(staffOrderStatusErrorMessage(error));
      await _loadOrders(showLoading: false);
    } finally {
      if (mounted) {
        setState(() => _busyOrderIds.remove(order.id));
      }
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// The kitchen's orders, oldest first.
  ///
  /// The read returns every status newest first, so the filter and the sort are done
  /// here and are described as such: the server narrows by restaurant and branch, and
  /// this screen decides what a cook needs to see. The order number breaks a tie so two
  /// orders placed in the same second still come out the same way every rebuild.
  List<StaffOrderModel> get _kitchenOrders {
    final visible = [
      for (final order in _orders)
        if (kitchenVisibleStatuses.contains(order.status)) order,
    ];
    visible.sort((a, b) {
      final byCreatedAt = a.createdAt.compareTo(b.createdAt);
      if (byCreatedAt != 0) {
        return byCreatedAt;
      }
      return a.orderNumber.compareTo(b.orderNumber);
    });
    return visible;
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return _withRealtimeNotice(const _KitchenLoadingState());
    }

    if (_errorMessage case final message?) {
      return _withRealtimeNotice(
        _KitchenErrorState(message: message, onRetry: _refresh),
      );
    }

    final orders = _kitchenOrders;
    if (orders.isEmpty) {
      return _withRealtimeNotice(_KitchenEmptyState(onRefresh: _refresh));
    }

    return _withRealtimeNotice(_buildOrderList(context, orders));
  }

  /// Adds the not-live notice above the page when the realtime channel cannot
  /// keep the list current; a stale list must never be mistaken for the answer.
  Widget _withRealtimeNotice(Widget child) {
    final message = _realtimeStatusMessage;
    if (message == null) {
      return child;
    }
    return Column(
      children: [
        _KitchenRealtimeNotice(message: message),
        Expanded(child: child),
      ],
    );
  }

  Widget _buildOrderList(
    BuildContext context,
    List<StaffOrderModel> orders,
  ) {
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.builder(
        key: const Key('kitchenList'),
        // Always scrollable so a short list can still be pulled to refresh; a kitchen
        // with one ticket should not have to wait for a second to check again.
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(24),
        itemCount: orders.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return _KitchenHeader(orderCount: orders.length);
          }

          final order = orders[index - 1];
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _KitchenOrderCard(
              order: order,
              now: _now,
              actions: staffOrderActionsFor(
                role: kitchenRole,
                status: order.status,
              ),
              isBusy: _busyOrderIds.contains(order.id),
              onAction: (target) => _changeStatus(order, target),
            ),
          );
        },
      ),
    );
  }
}

/// The list heading: how many tickets the kitchen is working, and in what order.
class _KitchenHeader extends StatelessWidget {
  const _KitchenHeader({required this.orderCount});

  final int orderCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final countLabel = orderCount == 1 ? '1 order' : '$orderCount orders';

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Kitchen', style: theme.textTheme.headlineMedium),
              ),
              Text(
                countLabel,
                key: const Key('kitchenCount'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          Text(
            'Oldest first, waiting orders and ones being made',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// One kitchen ticket.
///
/// The table and the order number lead because they are what is called out, then how
/// long the ticket has waited, then what is on it. No order id, no table id and no
/// guest credential is shown: a cook needs to know what to make and where it goes,
/// and nothing on this card needs any of them.
class _KitchenOrderCard extends StatelessWidget {
  const _KitchenOrderCard({
    required this.order,
    required this.now,
    required this.actions,
    required this.isBusy,
    required this.onAction,
  });

  final StaffOrderModel order;
  final DateTime now;
  final List<OrderStatus> actions;
  final bool isBusy;
  final ValueChanged<OrderStatus> onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final itemLabel = order.itemCount == 1
        ? '1 item'
        : '${order.itemCount} items';
    final elapsed = formatKitchenElapsed(now.difference(order.createdAt));

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        key: Key('kitchenCard_${order.id}'),
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
                      Text(
                        order.tableLabel,
                        key: Key('kitchenTable_${order.id}'),
                        style: theme.textTheme.titleLarge,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${order.numberLabel} · $itemLabel',
                        key: Key('kitchenOrderNumber_${order.id}'),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                StaffOrderStatusChip(status: order.status),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(
                  Icons.schedule_outlined,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Text(
                  elapsed,
                  key: Key('kitchenElapsed_${order.id}'),
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    formatOrderPlacedAt(order.createdAt),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final line in order.lines)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(line.label, style: theme.textTheme.bodyLarge),
                    ),
                ],
              ),
            ),
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final action in actions)
                    _KitchenActionButton(
                      status: action,
                      isBusy: isBusy,
                      onPressed: () => onAction(action),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A move offered on a ticket: the forward step filled, a cancellation toned.
class _KitchenActionButton extends StatelessWidget {
  const _KitchenActionButton({
    required this.status,
    required this.isBusy,
    required this.onPressed,
  });

  final OrderStatus status;
  final bool isBusy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final label = staffOrderActionLabel(status);
    final icon = isBusy
        ? const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(
            status == OrderStatus.cancelled
                ? Icons.cancel_outlined
                : Icons.arrow_forward,
            size: 18,
          );

    if (status == OrderStatus.cancelled) {
      return OutlinedButton.icon(
        key: staffOrderActionKey(status),
        onPressed: isBusy ? null : onPressed,
        icon: icon,
        label: Text(label),
      );
    }

    return FilledButton.icon(
      key: staffOrderActionKey(status),
      onPressed: isBusy ? null : onPressed,
      icon: icon,
      label: Text(label),
    );
  }
}

/// A narrow banner telling the kitchen the list is not live, so nobody mistakes a
/// stale list for the current answer. Pulling down still refreshes.
class _KitchenRealtimeNotice extends StatelessWidget {
  const _KitchenRealtimeNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const Key('kitchenRealtimeNotice'),
      width: double.infinity,
      color: theme.colorScheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(
            Icons.cloud_off_outlined,
            size: 18,
            color: theme.colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _KitchenLoadingState extends StatelessWidget {
  const _KitchenLoadingState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Loading kitchen orders...'),
        ],
      ),
    );
  }
}

class _KitchenErrorState extends StatelessWidget {
  const _KitchenErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

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
              Icons.cloud_off_outlined,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              message,
              key: const Key('kitchenErrorMessage'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('kitchenRetryButton'),
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

class _KitchenEmptyState extends StatelessWidget {
  const _KitchenEmptyState({required this.onRefresh});

  final VoidCallback onRefresh;

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
              Icons.soup_kitchen_outlined,
              size: 56,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              'No active kitchen orders',
              key: const Key('kitchenEmptyState'),
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'Orders waiting to be started or being made will appear here. '
              'Pull down to check again.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              key: const Key('kitchenEmptyRefreshButton'),
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh),
              label: const Text('Check again'),
            ),
          ],
        ),
      ),
    );
  }
}
