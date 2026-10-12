import 'package:flutter/material.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/models/staff_member_model.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/repositories/staff_member_repository.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/staff_member_error_message.dart';

/// Whether [role] may view and manage a restaurant's staff.
///
/// Only the two management roles may. The database enforces the same rule in
/// `private.has_restaurant_role(..., array['OWNER', 'MANAGER'])`, which backs
/// `staff_list_restaurant_members`; this copy exists so the screen can explain
/// itself to a waiter, a kitchen worker or a cashier instead of showing them a
/// backend refusal. It is not a second source of authority: a role changed on another
/// device, or a caller editing this function, changes nothing about what the database
/// will answer.
bool staffRoleManagesMembers(String role) {
  final normalized = role.trim().toUpperCase();
  return normalized == 'OWNER' || normalized == 'MANAGER';
}

/// The restaurant's staff list, for its owners and managers.
///
/// Every member comes from `staff_list_restaurant_members` through
/// [StaffMemberRepository], which is the only read path. `public.restaurant_members`
/// and `public.profiles` are never queried directly from here: the function returns
/// the exact fields this screen shows and nothing else, and this page opens no
/// management action, because none is implemented yet.
///
/// The page reads the signed-in [role] and decides what to show before it touches the
/// network. An owner or manager gets the list; anybody else gets a short explanation
/// of who may see it, so an unauthorized role never sees a raw database error for a
/// read it was never meant to make. The read itself is still authorized in the
/// database, which is what actually keeps a restaurant's staff private.
class StaffMembersPage extends StatefulWidget {
  const StaffMembersPage({
    super.key,
    required this.restaurantId,
    required this.role,
    this.repository = const StaffMemberRepository(),
  });

  /// The restaurant whose staff are listed.
  final String restaurantId;

  /// The signed-in member's role, which decides whether the list is offered at all.
  final String role;

  final StaffMemberRepository repository;

  @override
  State<StaffMembersPage> createState() => _StaffMembersPageState();
}

class _StaffMembersPageState extends State<StaffMembersPage> {
  List<StaffMemberModel> _members = const [];
  bool _isLoading = true;
  String? _errorMessage;

  bool get _canManage => staffRoleManagesMembers(widget.role);

  @override
  void initState() {
    super.initState();
    if (_canManage) {
      _loadMembers();
    } else {
      _isLoading = false;
    }
  }

  Future<void> _loadMembers() async {
    if (!_canManage) {
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final members = await widget.repository.getMembers(
        restaurantId: widget.restaurantId,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _members = members;
        _isLoading = false;
      });
    } catch (error, stackTrace) {
      debugPrint('Loading staff members failed: $error\n$stackTrace');
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
        _errorMessage = staffMemberListErrorMessage(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_canManage) {
      return const _RestrictedState();
    }

    if (_isLoading) {
      return const _LoadingState();
    }

    if (_errorMessage case final message?) {
      return _ErrorState(message: message, onRetry: _loadMembers);
    }

    return RefreshIndicator(
      onRefresh: _loadMembers,
      child: _buildMembersList(context),
    );
  }

  Widget _buildMembersList(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Staff', style: theme.textTheme.headlineMedium),
            ),
            IconButton(
              key: const Key('staffMembersRefreshButton'),
              tooltip: 'Refresh',
              onPressed: _loadMembers,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (_members.isEmpty)
          const _EmptyState()
        else
          for (final member in _members) ...[
            _MemberCard(member: member),
            const SizedBox(height: 12),
          ],
      ],
    );
  }
}

/// The explanation an owner or manager does not need and any other role sees.
class _RestrictedState extends StatelessWidget {
  const _RestrictedState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      key: const Key('staffMembersRestricted'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.lock_outline,
              size: 56,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text('Staff', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              'Only owners and managers can view staff members.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoadingState extends StatelessWidget {
  const _LoadingState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      key: Key('staffMembersLoading'),
      child: CircularProgressIndicator(),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      key: const Key('staffMembersError'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 56,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              key: const Key('staffMembersRetryButton'),
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

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: const Key('staffMembersEmpty'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Icon(
              Icons.people_outline,
              size: 40,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text('No staff members yet', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Members of this restaurant will appear here.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MemberCard extends StatelessWidget {
  const _MemberCard({required this.member});

  final StaffMemberModel member;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = member.trimmedDisplayName ?? 'Unnamed staff member';

    return Card(
      key: Key('staffMember_${member.id}'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: member.isActive
                  ? theme.colorScheme.primaryContainer
                  : theme.colorScheme.surfaceContainerHighest,
              foregroundColor: member.isActive
                  ? theme.colorScheme.onPrimaryContainer
                  : theme.colorScheme.onSurfaceVariant,
              child: Text(_initial(name)),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: theme.textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    member.role,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            _StatusChip(isActive: member.isActive),
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.isActive});

  final bool isActive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final background = isActive
        ? theme.colorScheme.secondaryContainer
        : theme.colorScheme.surfaceContainerHighest;
    final foreground = isActive
        ? theme.colorScheme.onSecondaryContainer
        : theme.colorScheme.onSurfaceVariant;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        isActive ? 'Active' : 'Inactive',
        style: theme.textTheme.labelMedium?.copyWith(color: foreground),
      ),
    );
  }
}

String _initial(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) {
    return '?';
  }
  return trimmed.substring(0, 1).toUpperCase();
}
