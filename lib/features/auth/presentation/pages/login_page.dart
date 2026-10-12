import 'package:flutter/material.dart';
import 'package:menukg_flutter/features/auth/data/services/auth_service.dart';
import 'package:menukg_flutter/features/auth/presentation/auth_error_message.dart';
import 'package:menukg_flutter/features/auth/presentation/pages/register_page.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, this.authService = const AuthService()});

  final AuthService authService;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    FocusScope.of(context).unfocus();
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await widget.authService.signInWithEmail(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );
    } catch (error, stackTrace) {
      debugPrint('Sign in failed: $error\n$stackTrace');
      if (!mounted) {
        return;
      }
      setState(
        () => _errorMessage = authErrorMessage(error, isRegistration: false),
      );
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _openRegistration() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RegisterPage(authService: widget.authService),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sign in')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Welcome back',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 24),
                    TextFormField(
                      key: const Key('loginEmailField'),
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(labelText: 'Email'),
                      validator: _validateEmail,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      key: const Key('loginPasswordField'),
                      controller: _passwordController,
                      obscureText: true,
                      autofillHints: const [AutofillHints.password],
                      onFieldSubmitted: (_) => _signIn(),
                      decoration: const InputDecoration(labelText: 'Password'),
                      validator: _validatePassword,
                    ),
                    if (_errorMessage case final message?) ...[
                      const SizedBox(height: 16),
                      _ErrorMessage(message: message),
                    ],
                    const SizedBox(height: 24),
                    FilledButton(
                      key: const Key('loginSubmitButton'),
                      onPressed: _isLoading ? null : _signIn,
                      child: _isLoading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Sign in'),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      key: const Key('openRegisterButton'),
                      onPressed: _isLoading ? null : _openRegistration,
                      child: const Text('Create an account'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String? _validateEmail(String? value) {
  final email = value?.trim() ?? '';
  if (email.isEmpty) {
    return 'Enter your email address.';
  }
  if (!email.contains('@')) {
    return 'Enter a valid email address.';
  }
  return null;
}

String? _validatePassword(String? value) {
  if ((value ?? '').isEmpty) {
    return 'Enter your password.';
  }
  return null;
}

class _ErrorMessage extends StatelessWidget {
  const _ErrorMessage({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Text(
        message,
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      ),
    );
  }
}
