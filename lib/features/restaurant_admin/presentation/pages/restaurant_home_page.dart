import 'package:flutter/material.dart';
import 'package:menukg_flutter/features/auth/data/services/auth_service.dart';

/// Temporary restaurant landing page until restaurant administration is built.
class RestaurantHomePage extends StatefulWidget {
  const RestaurantHomePage({
    super.key,
    required this.restaurantName,
    required this.role,
    this.branchName,
    this.showCreationSuccess = false,
    this.authService = const AuthService(),
  });

  final String restaurantName;
  final String? branchName;
  final String role;
  final bool showCreationSuccess;
  final AuthService authService;

  @override
  State<RestaurantHomePage> createState() => _RestaurantHomePageState();
}

class _RestaurantHomePageState extends State<RestaurantHomePage> {
  bool _isSigningOut = false;
  String? _errorMessage;

  Future<void> _signOut() async {
    setState(() {
      _isSigningOut = true;
      _errorMessage = null;
    });

    try {
      await widget.authService.signOut();
    } catch (error, stackTrace) {
      debugPrint('Sign out failed: $error\n$stackTrace');
      if (!mounted) {
        return;
      }
      setState(
        () => _errorMessage = 'We could not sign you out. Please try again.',
      );
    } finally {
      if (mounted) {
        setState(() => _isSigningOut = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('MenuKG')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (widget.showCreationSuccess) ...[
                Text(
                  'Restaurant created successfully',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 16),
              ],
              Text(
                widget.restaurantName,
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              if (widget.branchName case final branchName?) ...[
                const SizedBox(height: 8),
                Text(branchName),
              ],
              const SizedBox(height: 8),
              Text('Role: ${widget.role}'),
              if (_errorMessage case final message?) ...[
                const SizedBox(height: 16),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    message,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton(
                key: const Key('restaurantHomeSignOutButton'),
                onPressed: _isSigningOut ? null : _signOut,
                child: _isSigningOut
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Sign out'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
