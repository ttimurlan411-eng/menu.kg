import 'dart:async';

import 'package:flutter/material.dart';
import 'package:menukg_flutter/features/auth/data/models/restaurant_bootstrap_result_model.dart';
import 'package:menukg_flutter/features/auth/data/models/restaurant_membership_model.dart';
import 'package:menukg_flutter/features/auth/data/repositories/restaurant_membership_repository.dart';
import 'package:menukg_flutter/features/auth/data/repositories/restaurant_repository.dart';
import 'package:menukg_flutter/features/auth/data/services/auth_service.dart';
import 'package:menukg_flutter/features/auth/presentation/pages/login_page.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/pages/create_restaurant_page.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/pages/restaurant_dashboard_page.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Displays the appropriate root page for the current auth and restaurant state.
class AuthGate extends StatefulWidget {
  const AuthGate({
    super.key,
    this.authService = const AuthService(),
    this.membershipRepository = const RestaurantMembershipRepository(),
    this.restaurantRepository = const RestaurantRepository(),
  });

  final AuthService authService;
  final RestaurantMembershipRepository membershipRepository;
  final RestaurantRepository restaurantRepository;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  StreamSubscription<AuthState>? _authStateSubscription;
  User? _user;
  _RestaurantAccess? _restaurantAccess;
  bool _isLoadingRestaurantAccess = false;
  String? _restaurantAccessError;

  @override
  void initState() {
    super.initState();
    _user = widget.authService.getCurrentUser();
    _authStateSubscription = widget.authService.authStateChanges.listen(
      _onAuthStateChanged,
    );
    if (_user != null) {
      _loadRestaurantAccess();
    }
  }

  void _onAuthStateChanged(AuthState authState) {
    if (!mounted) {
      return;
    }

    final user = authState.session?.user;
    if (user?.id == _user?.id) {
      return;
    }

    setState(() {
      _user = user;
      _restaurantAccess = null;
      _isLoadingRestaurantAccess = false;
      _restaurantAccessError = null;
    });

    if (user != null) {
      _loadRestaurantAccess();
    }
  }

  Future<void> _loadRestaurantAccess() async {
    final user = _user;
    if (user == null || _isLoadingRestaurantAccess) {
      return;
    }

    setState(() {
      _isLoadingRestaurantAccess = true;
      _restaurantAccessError = null;
    });

    try {
      final memberships = await widget.membershipRepository.getMyMemberships();
      final membership = _selectPreferredMembership(memberships);

      if (membership == null) {
        _setLoadedRestaurantAccess(user.id, null);
        return;
      }

      final restaurant = await widget.restaurantRepository.getRestaurantSummary(
        membership.restaurantId,
      );
      if (restaurant == null) {
        throw StateError('Active restaurant membership has no visible restaurant.');
      }

      _setLoadedRestaurantAccess(
        user.id,
        _RestaurantAccess(
          restaurantId: restaurant.id,
          restaurantName: restaurant.name,
          branchName: restaurant.branchName,
          branchId: restaurant.branchId,
          role: membership.role,
          userEmail: user.email,
          membershipCount: memberships.length,
        ),
      );
    } catch (error, stackTrace) {
      debugPrint('Restaurant access lookup failed: $error\n$stackTrace');
      if (!mounted || _user?.id != user.id) {
        return;
      }
      setState(() {
        _isLoadingRestaurantAccess = false;
        _restaurantAccessError =
            'We could not load your restaurant. Please try again.';
      });
    }
  }

  void _setLoadedRestaurantAccess(String userId, _RestaurantAccess? access) {
    if (!mounted || _user?.id != userId) {
      return;
    }

    setState(() {
      _restaurantAccess = access;
      _isLoadingRestaurantAccess = false;
    });
  }

  /// The order in which the active memberships of one user are preferred.
  ///
  /// Management roles first, then the two roles that work orders, then a CASHIER.
  /// Every role the product knows beats sending a signed-in member to the
  /// restaurant creation form, which is only for a user with no active
  /// membership at all. What a role may actually do is decided by the database,
  /// not by this list: a CASHIER lands on the same dashboard as everyone else,
  /// where the screens that belong to them refuse what their role cannot do.
  static const List<String> _membershipPriority = [
    'OWNER',
    'MANAGER',
    'WAITER',
    'KITCHEN',
    'CASHIER',
  ];

  /// Chooses which membership the signed-in member works with.
  ///
  /// Active memberships only, scanned in [_membershipPriority] order, so a
  /// person who belongs to several restaurants lands on the one where their
  /// responsibility is the highest rather than on a random one. Inactive
  /// memberships are never chosen. Returns `null` when there is nothing active,
  /// which sends the caller to restaurant creation — the right answer for a new
  /// user, and only for a user with no active membership at all.
  RestaurantMembershipModel? _selectPreferredMembership(
    List<RestaurantMembershipModel> memberships,
  ) {
    for (final role in _membershipPriority) {
      for (final membership in memberships) {
        if (membership.isActive && membership.role == role) {
          return membership;
        }
      }
    }
    return null;
  }

  void _onRestaurantCreated(RestaurantBootstrapResultModel restaurant) {
    if (!mounted) {
      return;
    }

    setState(() {
      _restaurantAccess = _RestaurantAccess(
        restaurantId: restaurant.restaurantId,
        restaurantName: restaurant.name,
        branchName: restaurant.branchName,
        branchId: restaurant.branchId,
        role: 'OWNER',
        userEmail: _user?.email,
        membershipCount: 1,
        showCreationSuccess: true,
      );
      _restaurantAccessError = null;
    });
  }

  @override
  void dispose() {
    _authStateSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = _user;
    if (user == null) {
      return LoginPage(authService: widget.authService);
    }

    if (_isLoadingRestaurantAccess) {
      return const _RestaurantAccessLoadingPage();
    }

    if (_restaurantAccessError != null) {
      return _RestaurantAccessErrorPage(
        message: _restaurantAccessError!,
        onRetry: _loadRestaurantAccess,
      );
    }

    final restaurantAccess = _restaurantAccess;
    if (restaurantAccess == null) {
      return CreateRestaurantPage(
        authService: widget.authService,
        restaurantRepository: widget.restaurantRepository,
        onRestaurantCreated: _onRestaurantCreated,
      );
    }

    return RestaurantDashboardPage(
      restaurantId: restaurantAccess.restaurantId,
      restaurantName: restaurantAccess.restaurantName,
      branchName: restaurantAccess.branchName,
      branchId: restaurantAccess.branchId,
      role: restaurantAccess.role,
      userEmail: restaurantAccess.userEmail,
      membershipCount: restaurantAccess.membershipCount,
      showCreationSuccess: restaurantAccess.showCreationSuccess,
      authService: widget.authService,
    );
  }
}

class _RestaurantAccess {
  const _RestaurantAccess({
    required this.restaurantId,
    required this.restaurantName,
    required this.branchName,
    required this.role,
    required this.userEmail,
    required this.membershipCount,
    this.branchId,
    this.showCreationSuccess = false,
  });

  final String restaurantId;
  final String restaurantName;
  final String? branchName;

  /// Branch id used to scope table management.
  final String? branchId;

  final String role;
  final String? userEmail;
  final int membershipCount;
  final bool showCreationSuccess;
}

class _RestaurantAccessLoadingPage extends StatelessWidget {
  const _RestaurantAccessLoadingPage();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}

class _RestaurantAccessErrorPage extends StatelessWidget {
  const _RestaurantAccessErrorPage({
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: onRetry, child: const Text('Try again')),
            ],
          ),
        ),
      ),
    );
  }
}
