import 'package:flutter/material.dart';
import 'package:menukg_flutter/features/auth/data/services/auth_service.dart';
import 'package:menukg_flutter/features/auth/presentation/auth_error_message.dart';

class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key, this.authService = const AuthService()});

  final AuthService authService;

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;
  String? _statusMessage;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    FocusScope.of(context).unfocus();
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _statusMessage = null;
    });

    try {
      final response = await widget.authService.signUpWithEmail(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );
      if (!mounted) {
        return;
      }

      if (response.session == null) {
        setState(() {
          _statusMessage =
              'Check your email to confirm your account, then sign in.';
        });
      } else {
        Navigator.of(context).pop();
      }
    } catch (error, stackTrace) {
      debugPrint('Registration failed: $error\n$stackTrace');
      if (!mounted) {
        return;
      }
      setState(
        () => _errorMessage = authErrorMessage(error, isRegistration: true),
      );
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Create account')),
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
                      'Create your account',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 24),
                    TextFormField(
                      key: const Key('registerEmailField'),
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(labelText: 'Email'),
                      validator: _validateEmail,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      key: const Key('registerPasswordField'),
                      controller: _passwordController,
                      obscureText: true,
                      autofillHints: const [AutofillHints.newPassword],
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(labelText: 'Password'),
                      validator: _validatePassword,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      key: const Key('registerConfirmPasswordField'),
                      controller: _confirmPasswordController,
                      obscureText: true,
                      autofillHints: const [AutofillHints.newPassword],
                      onFieldSubmitted: (_) => _register(),
                      decoration: const InputDecoration(
                        labelText: 'Confirm password',
                      ),
                      validator: _validateConfirmPassword,
                    ),
                    if (_errorMessage case final message?) ...[
                      const SizedBox(height: 16),
                      _Message(message: message, isError: true),
                    ],
                    if (_statusMessage case final message?) ...[
                      const SizedBox(height: 16),
                      _Message(message: message),
                    ],
                    const SizedBox(height: 24),
                    FilledButton(
                      key: const Key('registerSubmitButton'),
                      onPressed: _isLoading ? null : _register,
                      child: _isLoading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Register'),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      key: const Key('backToLoginButton'),
                      onPressed: _isLoading
                          ? null
                          : () => Navigator.of(context).pop(),
                      child: const Text('Already have an account? Sign in'),
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

  String? _validateConfirmPassword(String? value) {
    if ((value ?? '').isEmpty) {
      return 'Confirm your password.';
    }
    if (value != _passwordController.text) {
      return 'Passwords do not match.';
    }
    return null;
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
    return 'Enter a password.';
  }
  return null;
}

class _Message extends StatelessWidget {
  const _Message({required this.message, this.isError = false});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Text(
        message,
        style: isError
            ? TextStyle(color: Theme.of(context).colorScheme.error)
            : null,
      ),
    );
  }
}
