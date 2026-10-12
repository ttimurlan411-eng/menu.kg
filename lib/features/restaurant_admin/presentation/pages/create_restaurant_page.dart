import 'package:flutter/material.dart';
import 'package:menukg_flutter/features/auth/data/models/restaurant_bootstrap_result_model.dart';
import 'package:menukg_flutter/features/auth/data/repositories/restaurant_repository.dart';
import 'package:menukg_flutter/features/auth/data/services/auth_service.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/pages/restaurant_home_page.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/restaurant_creation_error_message.dart';

final _urlSafeSlug = RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$');

/// Trims and lowercases a user-provided restaurant slug without generating one.
String normalizeRestaurantSlug(String value) => value.trim().toLowerCase();

String? validateRestaurantSlug(String? value) {
  final slug = normalizeRestaurantSlug(value ?? '');
  if (slug.isEmpty) {
    return 'Enter a restaurant slug.';
  }
  if (!_urlSafeSlug.hasMatch(slug)) {
    return 'Use lowercase letters, numbers, and hyphens only.';
  }
  return null;
}

class CreateRestaurantPage extends StatefulWidget {
  const CreateRestaurantPage({
    super.key,
    this.restaurantRepository = const RestaurantRepository(),
    this.authService = const AuthService(),
    this.onRestaurantCreated,
  });

  final RestaurantRepository restaurantRepository;
  final AuthService authService;
  final ValueChanged<RestaurantBootstrapResultModel>? onRestaurantCreated;

  @override
  State<CreateRestaurantPage> createState() => _CreateRestaurantPageState();
}

class _CreateRestaurantPageState extends State<CreateRestaurantPage> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _slugController = TextEditingController();
  final _currencyController = TextEditingController(text: 'KGS');
  final _defaultLanguageController = TextEditingController(text: 'ky');
  final _branchNameController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _nameController.dispose();
    _slugController.dispose();
    _currencyController.dispose();
    _defaultLanguageController.dispose();
    _branchNameController.dispose();
    super.dispose();
  }

  Future<void> _createRestaurant() async {
    FocusScope.of(context).unfocus();
    _normalizeEditableValues();
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final result = await widget.restaurantRepository.createRestaurant(
        name: _nameController.text.trim(),
        slug: _slugController.text,
        branchName: _branchNameController.text.trim(),
        currency: _currencyController.text,
        defaultLanguage: _defaultLanguageController.text,
      );

      if (!mounted) {
        return;
      }
      if (result == null) {
        setState(() {
          _errorMessage = 'Your session has ended. Please sign in again.';
        });
        return;
      }

      final onRestaurantCreated = widget.onRestaurantCreated;
      if (onRestaurantCreated != null) {
        onRestaurantCreated(result);
        return;
      }

      await Navigator.of(context).pushReplacement<void, void>(
        MaterialPageRoute<void>(
          builder: (_) => RestaurantHomePage(
            restaurantName: result.name,
            branchName: result.branchName,
            role: 'OWNER',
            showCreationSuccess: true,
            authService: widget.authService,
          ),
        ),
      );
    } catch (error, stackTrace) {
      debugPrint('Restaurant creation failed: $error\n$stackTrace');
      if (!mounted) {
        return;
      }
      setState(() => _errorMessage = restaurantCreationErrorMessage(error));
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _normalizeEditableValues() {
    _slugController.text = normalizeRestaurantSlug(_slugController.text);
    _currencyController.text = _currencyController.text.trim().toUpperCase();
    _defaultLanguageController.text = _defaultLanguageController.text.trim();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Create restaurant')),
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
                      'Create your restaurant',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 24),
                    TextFormField(
                      key: const Key('restaurantNameField'),
                      controller: _nameController,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Restaurant name',
                      ),
                      validator: _validateRequiredRestaurantName,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      key: const Key('restaurantSlugField'),
                      controller: _slugController,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(labelText: 'Slug'),
                      validator: validateRestaurantSlug,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      key: const Key('restaurantCurrencyField'),
                      controller: _currencyController,
                      textCapitalization: TextCapitalization.characters,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(labelText: 'Currency'),
                      validator: _validateCurrency,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      key: const Key('restaurantLanguageField'),
                      controller: _defaultLanguageController,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Default language',
                      ),
                      validator: _validateDefaultLanguage,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      key: const Key('restaurantBranchNameField'),
                      controller: _branchNameController,
                      onFieldSubmitted: (_) => _createRestaurant(),
                      decoration: const InputDecoration(labelText: 'Branch name'),
                      validator: _validateRequiredBranchName,
                    ),
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
                      key: const Key('createRestaurantSubmitButton'),
                      onPressed: _isLoading ? null : _createRestaurant,
                      child: _isLoading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Create restaurant'),
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

String? _validateRequiredRestaurantName(String? value) {
  if ((value ?? '').trim().isEmpty) {
    return 'Enter a restaurant name.';
  }
  return null;
}

String? _validateRequiredBranchName(String? value) {
  if ((value ?? '').trim().isEmpty) {
    return 'Enter a branch name.';
  }
  return null;
}

String? _validateCurrency(String? value) {
  if ((value ?? '').trim().length != 3) {
    return 'Enter a three-letter currency code.';
  }
  return null;
}

String? _validateDefaultLanguage(String? value) {
  if ((value ?? '').trim().isEmpty) {
    return 'Enter a default language.';
  }
  return null;
}
