import 'package:flutter/material.dart';
import 'package:menukg_flutter/features/auth/data/services/auth_service.dart';
import 'package:menukg_flutter/features/kitchen/presentation/pages/kitchen_page.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/repositories/category_repository.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/repositories/menu_item_repository.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/repositories/staff_member_repository.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/repositories/staff_order_repository.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/repositories/staff_reservation_repository.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/repositories/table_repository.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/pages/bookings_page.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/pages/categories_page.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/pages/module_placeholder_page.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/pages/products_page.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/pages/staff_members_page.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/pages/staff_orders_page.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/pages/tables_page.dart';

/// A section of the restaurant admin dashboard.
///
/// Dashboard, Categories, Products, Tables, Orders, Bookings, Staff and Kitchen show
/// real content today; every other section renders a placeholder until its module is
/// implemented. QR Codes opens the Tables page, where each table exposes its own
/// QR code. Staff is offered to every role, as before, and explains itself to a role
/// that may not manage members rather than hiding the section.
///
/// Kitchen is offered only to a member whose role is `KITCHEN`: it is that role's
/// working screen, and the other roles work orders on the Orders section. Every other
/// section is offered to every role, as before.
enum AdminDashboardSection {
  dashboard('Dashboard', Icons.dashboard_outlined),
  categories('Categories', Icons.category_outlined),
  products('Products', Icons.restaurant_menu_outlined),
  tables('Tables', Icons.table_restaurant_outlined),
  qrCodes('QR Codes', Icons.qr_code_2_outlined),
  orders('Orders', Icons.receipt_long_outlined),
  kitchen('Kitchen', Icons.soup_kitchen_outlined),
  bookings('Bookings', Icons.event_outlined),
  staff('Staff', Icons.people_outline),
  analytics('Analytics', Icons.insights_outlined),
  settings('Settings', Icons.settings_outlined);

  const AdminDashboardSection(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// The authenticated restaurant admin shell with navigation and a dashboard.
class RestaurantDashboardPage extends StatefulWidget {
  const RestaurantDashboardPage({
    super.key,
    required this.restaurantId,
    required this.restaurantName,
    required this.role,
    required this.userEmail,
    this.branchName,
    this.branchId,
    this.membershipCount,
    this.showCreationSuccess = false,
    this.authService = const AuthService(),
    this.categoryRepository = const CategoryRepository(),
    this.menuItemRepository = const MenuItemRepository(),
    this.tableRepository = const TableRepository(),
    this.staffOrderRepository = const StaffOrderRepository(),
    this.staffReservationRepository = const StaffReservationRepository(),
    this.staffMemberRepository = const StaffMemberRepository(),
  });

  /// Id of the current restaurant.
  final String restaurantId;

  /// Display name of the current restaurant.
  final String restaurantName;

  /// Name of the active branch, when one is available.
  final String? branchName;

  /// Id of the active branch. Tables require a `branch_id`.
  final String? branchId;

  /// The authenticated user's role in this restaurant.
  final String role;

  /// Email of the authenticated user.
  final String? userEmail;

  /// Number of restaurant memberships the user has, when known.
  final int? membershipCount;

  /// Whether the restaurant was just created; shows a success banner.
  final bool showCreationSuccess;

  final AuthService authService;

  final CategoryRepository categoryRepository;

  final MenuItemRepository menuItemRepository;

  final TableRepository tableRepository;

  /// Reads and moves orders, for every role that works them. Injected so the orders
  /// list is exercised without a database.
  final StaffOrderRepository staffOrderRepository;

  /// Reads and cancels reservations, for every role that works them. Injected so
  /// the bookings list is exercised without a database.
  final StaffReservationRepository staffReservationRepository;

  /// Reads the restaurant's members, for owners and managers. Injected so the staff
  /// list is exercised without a database.
  final StaffMemberRepository staffMemberRepository;

  @override
  State<RestaurantDashboardPage> createState() =>
      _RestaurantDashboardPageState();
}

class _RestaurantDashboardPageState extends State<RestaurantDashboardPage> {
  static const double _sidebarWidth = 264;
  static const double _wideLayoutBreakpoint = 840;

  AdminDashboardSection _selectedSection = AdminDashboardSection.dashboard;
  bool _isSigningOut = false;

  Future<void> _signOut() async {
    setState(() => _isSigningOut = true);

    try {
      await widget.authService.signOut();
    } catch (error, stackTrace) {
      debugPrint('Sign out failed: $error\n$stackTrace');
      if (!mounted) {
        return;
      }
      setState(() => _isSigningOut = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('We could not sign you out. Please try again.'),
        ),
      );
    }
  }

  void _selectSection(AdminDashboardSection section) {
    setState(() => _selectedSection = section);
  }

  /// The sections the signed-in role is offered.
  ///
  /// Kitchen is the kitchen role's screen and is offered only to it. Every other
  /// section is offered to every role exactly as it was, so no other role's
  /// navigation changes.
  List<AdminDashboardSection> get _visibleSections {
    final worksKitchen = widget.role.trim().toUpperCase() == 'KITCHEN';
    return [
      for (final section in AdminDashboardSection.values)
        if (section != AdminDashboardSection.kitchen || worksKitchen) section,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width >= _wideLayoutBreakpoint;
    final sections = _visibleSections;
    return Scaffold(
      appBar: _buildAppBar(context, isWide),
      drawer: isWide ? null : _buildMobileDrawer(sections),
      body: Row(
        children: [
          if (isWide)
            SizedBox(
              width: _sidebarWidth,
              child: _AdminSidebar(
                sections: sections,
                restaurantName: widget.restaurantName,
                branchName: widget.branchName,
                role: widget.role,
                userEmail: widget.userEmail,
                membershipCount: widget.membershipCount,
                selectedSection: _selectedSection,
                onSelected: _selectSection,
              ),
            ),
          Expanded(child: _buildSelectedContent(context)),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context, bool isWide) {
    final theme = Theme.of(context);
    final subtitleParts = <String>[
      ?widget.branchName,
      ?widget.userEmail,
    ];

    return AppBar(
      title: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.restaurantName, overflow: TextOverflow.ellipsis),
          if (isWide && subtitleParts.isNotEmpty)
            Text(
              subtitleParts.join(' · '),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
      actions: [
        if (isWide)
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: _SignOutButton(
              isLoading: _isSigningOut,
              onPressed: _isSigningOut ? null : _signOut,
            ),
          )
        else
          IconButton(
            key: const Key('dashboardSignOutButton'),
            tooltip: 'Sign out',
            onPressed: _isSigningOut ? null : _signOut,
            icon: const Icon(Icons.logout),
          ),
      ],
    );
  }

  Widget _buildMobileDrawer(List<AdminDashboardSection> sections) {
    return Drawer(
      child: _AdminSidebar(
        sections: sections,
        restaurantName: widget.restaurantName,
        branchName: widget.branchName,
        role: widget.role,
        userEmail: widget.userEmail,
        membershipCount: widget.membershipCount,
        selectedSection: _selectedSection,
        onSelected: (section) {
          Navigator.of(context).pop();
          _selectSection(section);
        },
      ),
    );
  }

  Widget _buildSelectedContent(BuildContext context) {
    switch (_selectedSection) {
      case AdminDashboardSection.dashboard:
        return _DashboardOverview(
          restaurantName: widget.restaurantName,
          branchName: widget.branchName,
          role: widget.role,
          membershipCount: widget.membershipCount,
          showCreationSuccess: widget.showCreationSuccess,
        );
      case AdminDashboardSection.categories:
        return CategoriesPage(
          restaurantId: widget.restaurantId,
          repository: widget.categoryRepository,
        );
      case AdminDashboardSection.products:
        return ProductsPage(
          restaurantId: widget.restaurantId,
          menuItemRepository: widget.menuItemRepository,
          categoryRepository: widget.categoryRepository,
        );
      case AdminDashboardSection.orders:
        return StaffOrdersPage(
          restaurantId: widget.restaurantId,
          role: widget.role,
          branchId: widget.branchId,
          repository: widget.staffOrderRepository,
        );
      case AdminDashboardSection.kitchen:
        return KitchenPage(
          restaurantId: widget.restaurantId,
          branchId: widget.branchId,
          repository: widget.staffOrderRepository,
        );
      case AdminDashboardSection.bookings:
        return BookingsPage(
          restaurantId: widget.restaurantId,
          branchId: widget.branchId,
          repository: widget.staffReservationRepository,
          // The same table source the Tables section uses, so a booking's table
          // is labelled from the restaurant's own tables rather than a second
          // read path.
          tableRepository: widget.tableRepository,
        );
      case AdminDashboardSection.staff:
        return StaffMembersPage(
          restaurantId: widget.restaurantId,
          role: widget.role,
          repository: widget.staffMemberRepository,
        );
      case AdminDashboardSection.tables:
      case AdminDashboardSection.qrCodes:
        final branchId = widget.branchId;
        if (branchId == null) {
          return const ModulePlaceholderPage(
            moduleName: 'Tables',
            icon: Icons.table_restaurant_outlined,
          );
        }
        return TablesPage(
          restaurantId: widget.restaurantId,
          branchId: branchId,
          repository: widget.tableRepository,
        );
      default:
        return ModulePlaceholderPage(
          moduleName: _selectedSection.label,
          icon: _selectedSection.icon,
        );
    }
  }
}

class _SignOutButton extends StatelessWidget {
  const _SignOutButton({this.isLoading = false, this.onPressed});

  final bool isLoading;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      key: const Key('dashboardSignOutButton'),
      onPressed: onPressed,
      icon: isLoading
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.logout),
      label: const Text('Sign out'),
    );
  }
}

class _AdminSidebar extends StatelessWidget {
  const _AdminSidebar({
    required this.sections,
    required this.restaurantName,
    required this.branchName,
    required this.role,
    required this.userEmail,
    required this.membershipCount,
    required this.selectedSection,
    required this.onSelected,
  });

  /// The sections to render, already filtered for the signed-in role.
  final List<AdminDashboardSection> sections;

  final String restaurantName;
  final String? branchName;
  final String role;
  final String? userEmail;
  final int? membershipCount;
  final AdminDashboardSection selectedSection;
  final ValueChanged<AdminDashboardSection> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SidebarHeader(
              restaurantName: restaurantName,
              branchName: branchName,
              role: role,
              userEmail: userEmail,
              membershipCount: membershipCount,
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(
                  vertical: 8,
                  horizontal: 8,
                ),
                children: [
                  for (final section in sections)
                    _buildNavigationTile(context, section),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNavigationTile(
    BuildContext context,
    AdminDashboardSection section,
  ) {
    final theme = Theme.of(context);
    final isSelected = section == selectedSection;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: ListTile(
        key: Key('adminNav_${section.name}'),
        leading: Icon(section.icon),
        title: Text(section.label),
        selected: isSelected,
        selectedTileColor: theme.colorScheme.secondaryContainer,
        onTap: () => onSelected(section),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }
}

class _SidebarHeader extends StatelessWidget {
  const _SidebarHeader({
    required this.restaurantName,
    required this.branchName,
    required this.role,
    required this.userEmail,
    required this.membershipCount,
  });

  final String restaurantName;
  final String? branchName;
  final String role;
  final String? userEmail;
  final int? membershipCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final membershipLabel = switch (membershipCount) {
      null => null,
      1 => '1 membership',
      final count => '$count memberships',
    };

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: theme.colorScheme.onPrimary,
                child: Text(_restaurantInitial(restaurantName)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      restaurantName,
                      style: theme.textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (branchName case final branch?)
                      Text(
                        branch,
                        style: theme.textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          _headerDetail(theme, Icons.badge_outlined, role),
          if (userEmail case final email?)
            _headerDetail(theme, Icons.mail_outline, email),
          if (membershipLabel case final label?)
            _headerDetail(theme, Icons.groups_outlined, label),
        ],
      ),
    );
  }

  Widget _headerDetail(ThemeData theme, IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

String _restaurantInitial(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) {
    return 'R';
  }
  return trimmed.substring(0, 1).toUpperCase();
}

class _DashboardOverview extends StatelessWidget {
  const _DashboardOverview({
    required this.restaurantName,
    required this.branchName,
    required this.role,
    required this.membershipCount,
    required this.showCreationSuccess,
  });

  final String restaurantName;
  final String? branchName;
  final String role;
  final int? membershipCount;
  final bool showCreationSuccess;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cards = <_InfoCardData>[
      _InfoCardData('Restaurant', restaurantName, Icons.storefront_outlined),
      _InfoCardData(
        'Branch',
        branchName ?? 'Not set',
        Icons.location_on_outlined,
      ),
      _InfoCardData('Role', role, Icons.badge_outlined),
      _InfoCardData(
        'Memberships',
        membershipCount?.toString() ?? 'Not set',
        Icons.groups_outlined,
      ),
    ];

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        if (showCreationSuccess) ...[
          const _SuccessBanner(),
          const SizedBox(height: 20),
        ],
        Text('Dashboard', style: theme.textTheme.headlineMedium),
        const SizedBox(height: 20),
        Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            for (final card in cards)
              SizedBox(width: 240, child: _InfoCard(data: card)),
          ],
        ),
        const SizedBox(height: 24),
        Text('Upcoming modules', style: theme.textTheme.titleMedium),
        const SizedBox(height: 12),
        const _EmptyStateCard(
          icon: Icons.insights_outlined,
          title: 'Analytics',
          message:
              'Analytics will appear here after the analytics module is implemented.',
        ),
      ],
    );
  }
}

class _InfoCardData {
  const _InfoCardData(this.label, this.value, this.icon);

  final String label;
  final String value;
  final IconData icon;
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.data});

  final _InfoCardData data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(data.icon, size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    data.label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              data.value,
              style: theme.textTheme.titleLarge,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyStateCard extends StatelessWidget {
  const _EmptyStateCard({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(message, style: theme.textTheme.bodyMedium),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SuccessBanner extends StatelessWidget {
  const _SuccessBanner();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            Icons.check_circle_outline,
            color: theme.colorScheme.onSecondaryContainer,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Restaurant created successfully',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}