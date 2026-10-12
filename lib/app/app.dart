import 'package:flutter/material.dart';
import 'package:menukg_flutter/app/router/app_router.dart';
import 'package:menukg_flutter/app/theme/app_theme.dart';
import 'package:menukg_flutter/features/auth/data/services/auth_service.dart';

class MenukgApp extends StatelessWidget {
  const MenukgApp({super.key, this.authService = const AuthService()});

  final AuthService authService;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MenuKG',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      home: AppRouter.initialPage(authService: authService),
      // Public routes are resolved here so they bypass AuthGate and never
      // require a session.
      onGenerateRoute: AppRouter.onGenerateRoute,
    );
  }
}
