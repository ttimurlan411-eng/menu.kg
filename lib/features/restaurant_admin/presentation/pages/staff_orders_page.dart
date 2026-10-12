import 'dart:async';

import 'package:flutter/material.dart';
import 'package:menukg_flutter/features/customer/orders/data/models/order_model.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/models/staff_order_model.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/repositories/staff_order_repository.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/pages/staff_order_details_page.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/staff_order_actions.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/staff_order_error_message.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/widgets/staff_order_status_chip.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Which read the staff orders screen is showing.
///
/// [active] is the live working list the page has always shown — PENDING, ACCEPTED,
/// PREPARING and READY — fed by `staff_list_active_orders` and Realtime. [history] is
/// the same restaurant's whole chronological list, every status, fed by
/// `staff_list_order_history` one page at a time. The two are one screen because they
/// are two questions asked of the same orders, and a staff member should not lose
/// their place to move between them.
enum _OrdersView { active, history }

/// The staff orders dashboard: the restaurant's live order list and its history.
///
/// Every order here comes from `staff_list_active_orders` through
/// [StaffOrderRepository], and every status change goes through
/// `staff_set_order_status`. This page opens no table directly, because the orders
/// tables carry no grant for any client role: an order could not be read this way even
/// if this file asked for it.
///
/// The screen has two views, chosen by the selector at the top. The default, Active,
/// shows the active orders only: PENDING, ACCEPTED, PREPARING and READY. Completed and
/// cancelled orders are not in it. That is deliberate — the live working list must not
/// lose an order that still needs a person behind a large history.
///
/// History is the rest of the story: every status, read one page at a time from
/// `staff_list_order_history`, newest first. Its pages are found by cursor rather than
/// by OFFSET, so a page cannot be shifted by an order placed while a staff member is
/// reading, and it is refreshed by pulling down rather than by Realtime. Switching to
/// History reads its first page; switching back to Active does not disturb the live
/// list, which keeps its own subscription.
///
/// What it shows is chosen for a person standing in a restaurant looking at a list:
/// the table and the order number first, since those are what is read out loud and
/// carried to the table; the status next, as a coloured chip with a word on it rather
/// than as colour alone; and then the time, the item count and the stored total.
/// Newest first, which is the order `staff_list_active_orders` already returns, so
/// this page does not re-sort a list the database put in the order a staff member
/// wants.
///
/// There is deliberately no filter, no search and no grouping by status here. They
/// belong with a larger list, and a filter that hides orders is a filter that can
/// hide the order a guest is waiting for.
///
/// Realtime: the page subscribes to `order_change_events` and re-reads when an order
/// of this restaurant changes, so a newly placed order or a move made on another
/// screen appears without a pull to refresh. The channel is only a signal — the
/// database authorizes each event against the subscriber before it is delivered (the
/// row is invisible unless the caller is an active OWNER, MANAGER, WAITER or KITCHEN
/// of that restaurant), and the re-read goes through the same
/// `staff_list_active_orders` the page already uses. No `orders` table is subscribed
/// to, and the payload a screen
/// reacts to carries no access token and no order data: it is five columns, and the
/// order is then fetched from the one authorized read path.
class StaffOrdersPage extends StatefulWidget {
  const StaffOrdersPage({
    super.key,
    required this.restaurantId,
    required this.role,
    this.branchId,
    this.repository = const StaffOrderRepository(),
    this.supabaseClient,
    this.enableRealtime = true,
  });

  /// The restaurant whose orders are worked on this page.
  final String restaurantId;

  /// The signed-in member's role, which decides which moves are offered.
  final String role;

  /// The active branch, when the dashboard has one. Orders of a restaurant whose
  /// branch is not known are still read, because the read is scoped by restaurant and
  /// the database filters a branch that is named.
  final String? branchId;

  final StaffOrderRepository repository;

  final SupabaseClient? supabaseClient;
  final bool enableRealtime;

  SupabaseClient? get supabaseClientInstance => supabaseClient;

  @override
  State<StaffOrdersPage> createState() => _StaffOrdersPageState();
}

class _StaffOrdersPageState extends State<StaffOrdersPage> {
  List<StaffOrderModel> _orders = const [];
  bool _isLoading = true;
  String? _errorMessage;

  /// Which of the two reads this screen is showing. Active is the default, so the
  /// screen a staff member already knows is what they see when it opens.
  _OrdersView _view = _OrdersView.active;

  /// The history loaded so far, in the order the database sent the pages: newest
  /// first, page one then page two and so on. Pages are appended, never replaced, so
  /// scrolling back never loses a page already read.
  List<StaffOrderModel> _historyOrders = const [];

  /// True while the history's first page is being read.
  bool _historyIsLoading = false;

  /// Whether the first page has ever been read for the current scope. Switching to
  /// History reads once; switching back and forth does not re-read a list it holds.
  bool _historyLoaded = false;

  /// The first-page failure, shown in place of the list.
  String? _historyErrorMessage;

  /// Whether another page follows the ones loaded.
  bool _historyHasMore = false;

  /// Where the next page starts, from the database's own `next_cursor`.
  StaffOrderHistoryCursor? _historyCursor;

  /// True while one more page is in flight, so a scroll that reaches the bottom twice
  /// cannot start two reads for the same page.
  bool _historyLoadingMore = false;

  /// A failed "load more", shown at the foot of the list with a retry.
  String? _historyLoadMoreErrorMessage;

  final ScrollController _historyScrollController = ScrollController();

  /// Orders with a status change in flight, so two taps cannot race one order.
  final Set<String> _busyOrderIds = <String>{};

  RealtimeChannel? _realtimeChannel;

  /// Shown when the realtime channel cannot keep the list live, so the screen says
  /// so instead of silently going stale beside a guest's order.
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
    _loadOrders();
    _historyScrollController.addListener(_onHistoryScroll);
    if (widget.enableRealtime) {
      _setupRealtime();
    }
  }

  @override
  void didUpdateWidget(covariant StaffOrdersPage oldWidget) {
    super.didUpdateWidget(oldWidget);

    final scopeChanged = oldWidget.restaurantId != widget.restaurantId ||
        oldWidget.branchId != widget.branchId;
    if (!scopeChanged) {
      return;
    }

    // The screen answers for a different restaurant or branch now, so history read for
    // the old scope must not be shown beside the new scope's orders. The active list is
    // re-read through its usual pipeline; the history is dropped and re-read only if it
    // is the view on screen.
    setState(() {
      _historyOrders = const [];
      _historyLoaded = false;
      _historyIsLoading = false;
      _historyErrorMessage = null;
      _historyHasMore = false;
      _historyCursor = null;
      _historyLoadingMore = false;
      _historyLoadMoreErrorMessage = null;
    });

    if (_view == _OrdersView.history) {
      unawaited(_loadHistory());
    } else {
      unawaited(_loadOrders(showLoading: false));
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _historyScrollController.dispose();
    _completeAll(List.of(_pendingReads));
    _pendingReads.clear();
    if (_inFlightBatch case final batch?) {
      _completeAll(batch);
      _inFlightBatch = null;
    }
    if (widget.enableRealtime) {
      _unsubscribeRealtime();
    }
    super.dispose();
  }

  void _setupRealtime() {
    if (widget.restaurantId.trim().isEmpty) {
      return;
    }

    final client = widget.supabaseClientInstance ?? Supabase.instance.client;
    final channel = client.channel(
      'orders:order_change_events:${widget.restaurantId.trim()}',
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
        'Live order updates are unavailable. Pull down to refresh.',
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

  /// Switches between the active list and the history.
  ///
  /// History is read the first time it is shown and kept afterwards, so moving between
  /// the two views does not re-read what is already on screen. The active list's
  /// Realtime subscription is not touched by the switch: it keeps the live list
  /// current whether or not it is the view being shown.
  void _selectView(_OrdersView view) {
    if (view == _view) {
      return;
    }
    setState(() => _view = view);
    if (view == _OrdersView.history && !_historyLoaded && !_historyIsLoading) {
      unawaited(_loadHistory());
    }
  }

  /// Reads the history's first page and replaces what was loaded.
  ///
  /// [showLoading] is false for a pull to refresh or a reload behind an existing list,
  /// so the list already on screen stays while the next read runs.
  Future<void> _loadHistory({bool showLoading = true}) async {
    if (_historyIsLoading) {
      return;
    }
    if (showLoading) {
      setState(() {
        _historyIsLoading = true;
        _historyErrorMessage = null;
      });
    }

    try {
      final page = await widget.repository.getOrderHistory(
        restaurantId: widget.restaurantId,
        branchId: widget.branchId,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _historyOrders = page.orders;
        _historyHasMore = page.hasMore;
        _historyCursor = page.nextCursor;
        _historyIsLoading = false;
        _historyLoaded = true;
        _historyErrorMessage = null;
        _historyLoadMoreErrorMessage = null;
      });
    } catch (error, stackTrace) {
      debugPrint('Loading order history failed: $error\n$stackTrace');
      if (!mounted) {
        return;
      }
      // A first-page failure with nothing on screen is shown in place of the list; a
      // failure with a list already up is a message, so a refresh cannot blank a page
      // a staff member is reading.
      if (_historyOrders.isEmpty) {
        setState(() {
          _historyIsLoading = false;
          _historyErrorMessage = staffOrderListErrorMessage(error);
        });
      } else {
        setState(() => _historyIsLoading = false);
        _showMessage(staffOrderListErrorMessage(error));
      }
    }
  }

  /// Reads the next page and appends it to the history already on screen.
  ///
  /// Guarded so a scroll that reaches the bottom while a page is already in flight does
  /// not start a second read for the same page, and so the last page is not asked for
  /// again.
  Future<void> _loadMoreHistory() async {
    if (_historyLoadingMore || !_historyHasMore) {
      return;
    }
    final cursor = _historyCursor;
    if (cursor == null) {
      return;
    }

    setState(() {
      _historyLoadingMore = true;
      _historyLoadMoreErrorMessage = null;
    });

    try {
      final page = await widget.repository.getOrderHistory(
        restaurantId: widget.restaurantId,
        branchId: widget.branchId,
        cursor: cursor,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _historyOrders = [..._historyOrders, ...page.orders];
        _historyHasMore = page.hasMore;
        _historyCursor = page.nextCursor;
        _historyLoadingMore = false;
      });
    } catch (error, stackTrace) {
      debugPrint('Loading another history page failed: $error\n$stackTrace');
      if (!mounted) {
        return;
      }
      setState(() {
        _historyLoadingMore = false;
        _historyLoadMoreErrorMessage = staffOrderListErrorMessage(error);
      });
    }
  }

  /// Asks for the next page when the history is scrolled near its foot.
  void _onHistoryScroll() {
    if (!_historyScrollController.hasClients) {
      return;
    }
    if (_historyScrollController.position.extentAfter < 400) {
      unawaited(_loadMoreHistory());
    }
  }

  /// Re-reads whichever list is on screen, after a status change or a detail page.
  Future<void> _refreshCurrentView() {
    return _view == _OrdersView.history
        ? _loadHistory(showLoading: false)
        : _loadOrders(showLoading: false);
  }

  /// Loads the list.
  ///
  /// [showLoading] is false for a reload behind an existing list, so a status
  /// change, a pull to refresh or a realtime event does not replace a usable list
  /// with a spinner: the list stays on screen while the next read runs, which is
  /// what a waiter needs while an order is moving.
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
      debugPrint('Loading staff orders failed: $error\n$stackTrace');
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

  Future<void> _openOrder(StaffOrderModel order) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => StaffOrderDetailsPage(
          order: order,
          role: widget.role,
          repository: widget.repository,
        ),
      ),
    );

    // The details page changed the status of this order, or refused to, and another
    // device may have moved something since this list was read. Re-reading is the only
    // way to be sure the list on screen is the database's answer.
    await _refreshCurrentView();
  }

  /// Moves one order and keeps the list honest about what happened.
  ///
  /// A successful move is applied from the answer the database gave, including its
  /// own `updated_at`, rather than from what was asked for. A refusal is shown as the
  /// message `staffOrderStatusErrorMessage` built and then the list is re-read, because
  /// a move the backend refused may well have been made by someone else in the
  /// meantime and this list is not the authority on an order's status.
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
          'We could not confirm that change. Pull down to refresh the list.',
        );
        await _refreshCurrentView();
        return;
      }

      // Both lists can hold the order — the same order is in the active list and in
      // the history — so both are updated from the database's answer, and the one that
      // does not contain it is unchanged.
      setState(() {
        _orders = _applyStatusUpdate(_orders, order.id, update);
        _historyOrders = _applyStatusUpdate(_historyOrders, order.id, update);
      });
    } catch (error, stackTrace) {
      debugPrint('Changing an order status failed: $error\n$stackTrace');
      if (!mounted) {
        return;
      }
      _showMessage(staffOrderStatusErrorMessage(error));
      await _refreshCurrentView();
    } finally {
      if (mounted) {
        setState(() => _busyOrderIds.remove(order.id));
      }
    }
  }

  /// Returns [orders] with the order whose id is [orderId] moved to the status and
  /// moment [update] reports, and every other order untouched.
  ///
  /// A status change cannot alter an order's lines, totals or table, so nothing else
  /// is replaced; the list it is applied to either holds that order or is unchanged.
  List<StaffOrderModel> _applyStatusUpdate(
    List<StaffOrderModel> orders,
    String orderId,
    StaffOrderStatusUpdate update,
  ) {
    return [
      for (final existing in orders)
        if (existing.id == orderId)
          existing.withStatus(update.status, updatedAt: update.updatedAt)
        else
          existing,
    ];
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _OrdersViewSelector(view: _view, onChanged: _selectView),
        Expanded(
          child: _view == _OrdersView.active
              ? _buildActiveView()
              : _buildHistoryView(),
        ),
      ],
    );
  }

  /// The live list: the active orders, refreshed by Realtime, exactly as before this
  /// step added the history view.
  Widget _buildActiveView() {
    if (_isLoading) {
      return _withRealtimeNotice(const _OrdersLoadingState());
    }

    if (_errorMessage case final message?) {
      return _withRealtimeNotice(
        _OrdersErrorState(message: message, onRetry: _refresh),
      );
    }

    if (_orders.isEmpty) {
      return _withRealtimeNotice(_OrdersEmptyState(onRefresh: _refresh));
    }

    return _withRealtimeNotice(_buildOrderList(context));
  }

  /// The chronological history: every status, page by page, without a Realtime
  /// subscription. It is refreshed by pulling down, and the next page is read when the
  /// list is scrolled near its foot.
  Widget _buildHistoryView() {
    if (_historyIsLoading) {
      return const _OrdersLoadingState();
    }

    if (_historyErrorMessage case final message?) {
      return _OrdersErrorState(message: message, onRetry: _loadHistory);
    }

    if (_historyOrders.isEmpty) {
      return _OrdersEmptyState(onRefresh: _reloadHistory);
    }

    return RefreshIndicator(
      onRefresh: _reloadHistory,
      child: ListView.builder(
        key: const Key('staffOrdersHistoryList'),
        controller: _historyScrollController,
        padding: const EdgeInsets.all(24),
        // The header, the orders loaded so far, and a footer that loads the next page.
        itemCount: _historyOrders.length + 2,
        itemBuilder: (context, index) {
          if (index == 0) {
            return _OrdersHeader(
              orderCount: _historyOrders.length,
              isBranchScoped: (widget.branchId ?? '').trim().isNotEmpty,
              title: 'Order history',
              countLabel: _historyHasMore
                  ? '${_historyOrders.length}+ loaded'
                  : null,
            );
          }

          if (index == _historyOrders.length + 1) {
            return _HistoryFooter(
              hasMore: _historyHasMore,
              isLoading: _historyLoadingMore,
              errorMessage: _historyLoadMoreErrorMessage,
              onLoadMore: _loadMoreHistory,
            );
          }

          final order = _historyOrders[index - 1];
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _OrderCard(
              order: order,
              actions: staffOrderActionsFor(
                role: widget.role,
                status: order.status,
              ),
              isBusy: _busyOrderIds.contains(order.id),
              onTap: () => _openOrder(order),
              onAction: (target) => _changeStatus(order, target),
            ),
          );
        },
      ),
    );
  }

  Future<void> _reloadHistory() => _loadHistory(showLoading: false);

  /// Adds the not-live notice above the page when the realtime channel cannot
  /// keep the list current; a stale list must never be mistaken for the answer.
  Widget _withRealtimeNotice(Widget child) {
    final message = _realtimeStatusMessage;
    if (message == null) {
      return child;
    }
    return Column(
      children: [
        _RealtimeNotice(message: message),
        Expanded(child: child),
      ],
    );
  }

  Widget _buildOrderList(BuildContext context) {
    return RefreshIndicator(
      // The list itself is the scroll view, so the gesture is always reachable.
      onRefresh: _refresh,
      child: ListView.builder(
        key: const Key('staffOrdersList'),
        padding: const EdgeInsets.all(24),
        itemCount: _orders.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return _OrdersHeader(
              orderCount: _orders.length,
              isBranchScoped: (widget.branchId ?? '').trim().isNotEmpty,
            );
          }

          final order = _orders[index - 1];
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _OrderCard(
              order: order,
              actions: staffOrderActionsFor(
                role: widget.role,
                status: order.status,
              ),
              isBusy: _busyOrderIds.contains(order.id),
              onTap: () => _openOrder(order),
              onAction: (target) => _changeStatus(order, target),
            ),
          );
        },
      ),
    );
  }
}

/// The list heading: how many orders, and what is being shown.
class _OrdersHeader extends StatelessWidget {
  const _OrdersHeader({
    required this.orderCount,
    required this.isBranchScoped,
    this.title = 'Orders',
    this.countLabel,
  });

  final int orderCount;

  /// Whether the read was narrowed to one branch.
  final bool isBranchScoped;

  /// The heading text, `Orders` for the live list and `Order history` for the
  /// chronological view.
  final String title;

  /// The count wording, or `null` to derive it from [orderCount]. The history passes
  /// its own, because `50 orders` would claim a total the screen does not know — it
  /// has read 50 of however many exist.
  final String? countLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final resolvedCountLabel =
        countLabel ?? (orderCount == 1 ? '1 order' : '$orderCount orders');

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(title, style: theme.textTheme.headlineMedium),
              ),
              Text(
                resolvedCountLabel,
                key: const Key('staffOrdersCount'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          Text(
            isBranchScoped ? 'Newest first, for this branch' : 'Newest first',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// One order in the list.
class _OrderCard extends StatelessWidget {
  const _OrderCard({
    required this.order,
    required this.actions,
    required this.isBusy,
    required this.onTap,
    required this.onAction,
  });

  final StaffOrderModel order;
  final List<OrderStatus> actions;
  final bool isBusy;
  final VoidCallback onTap;
  final ValueChanged<OrderStatus> onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final itemLabel = order.itemCount == 1
        ? '1 item'
        : '${order.itemCount} items';

    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        key: Key('staffOrderCard_${order.id}'),
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
                        // The table and the number are what a guest is called for, so
                        // they lead and they are the largest text on the card.
                        Text(
                          order.tableLabel,
                          key: Key('staffOrderTable_${order.id}'),
                          style: theme.textTheme.titleLarge,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Order ${order.numberLabel} · $itemLabel · '
                          '${formatOrderPlacedAt(order.createdAt)}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      StaffOrderStatusChip(status: order.status),
                      const SizedBox(height: 8),
                      Text(
                        order.totalLabel,
                        style: theme.textTheme.titleSmall,
                      ),
                    ],
                  ),
                ],
              ),
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final action in actions)
                      _OrderActionButton(
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
      ),
    );
  }
}

/// A move offered on a list card, sized for a thumb rather than for a dialog.
class _OrderActionButton extends StatelessWidget {
  const _OrderActionButton({
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
    return TextButton.icon(
      key: staffOrderActionKey(status),
      onPressed: isBusy ? null : onPressed,
      icon: isBusy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.arrow_forward, size: 18),
      label: Text(label),
    );
  }
}

/// The Active / History selector at the top of the orders screen.
///
/// Two named choices rather than a swipe or a hidden gesture, so which list is on
/// screen is always readable and reachable. Active is the default.
class _OrdersViewSelector extends StatelessWidget {
  const _OrdersViewSelector({required this.view, required this.onChanged});

  final _OrdersView view;
  final ValueChanged<_OrdersView> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: SegmentedButton<_OrdersView>(
          key: const Key('staffOrdersViewSelector'),
          segments: const [
            ButtonSegment<_OrdersView>(
              value: _OrdersView.active,
              label: Text('Active'),
              icon: Icon(Icons.pending_actions_outlined),
            ),
            ButtonSegment<_OrdersView>(
              value: _OrdersView.history,
              label: Text('History'),
              icon: Icon(Icons.history),
            ),
          ],
          selected: {view},
          onSelectionChanged: (selection) => onChanged(selection.first),
          showSelectedIcon: false,
        ),
      ),
    );
  }
}

/// The foot of the history list: a spinner while the next page is read, a retry after
/// a failed page, a button that asks for one, or nothing when the last page is shown.
///
/// The button is a fallback for a list too short to scroll far enough to trigger the
/// automatic read; scrolling near the foot asks for the page on its own.
class _HistoryFooter extends StatelessWidget {
  const _HistoryFooter({
    required this.hasMore,
    required this.isLoading,
    required this.errorMessage,
    required this.onLoadMore,
  });

  final bool hasMore;
  final bool isLoading;
  final String? errorMessage;
  final Future<void> Function() onLoadMore;

  @override
  Widget build(BuildContext context) {
    if (!hasMore && errorMessage == null) {
      return const SizedBox.shrink();
    }

    if (isLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (errorMessage case final message?) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                message,
                key: const Key('staffOrdersHistoryLoadMoreError'),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                key: const Key('staffOrdersHistoryLoadMoreRetryButton'),
                onPressed: () => onLoadMore(),
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: TextButton.icon(
          key: const Key('staffOrdersHistoryLoadMoreButton'),
          onPressed: () => onLoadMore(),
          icon: const Icon(Icons.expand_more),
          label: const Text('Load more'),
        ),
      ),
    );
  }
}

/// A narrow banner telling staff the list is not live, so nobody mistakes a stale
/// list for the current answer. Pulling down still refreshes.
class _RealtimeNotice extends StatelessWidget {
  const _RealtimeNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const Key('staffOrdersRealtimeNotice'),
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

class _OrdersLoadingState extends StatelessWidget {
  const _OrdersLoadingState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Loading orders...'),
        ],
      ),
    );
  }
}

class _OrdersErrorState extends StatelessWidget {
  const _OrdersErrorState({required this.message, required this.onRetry});

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
              key: const Key('staffOrdersErrorMessage'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('staffOrdersRetryButton'),
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

class _OrdersEmptyState extends StatelessWidget {
  const _OrdersEmptyState({required this.onRefresh});

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
              Icons.receipt_long_outlined,
              size: 56,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              'No orders yet',
              key: const Key('staffOrdersEmptyState'),
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'Orders will appear here as guests place them at your tables.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              key: const Key('staffOrdersEmptyRefreshButton'),
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