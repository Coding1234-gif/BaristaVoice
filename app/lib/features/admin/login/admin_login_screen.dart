import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/admin_theme.dart';
import '../../../core/env.dart';
import '../../../state/auth_providers.dart';

enum _Mode { signIn, signUp }

class AdminLoginScreen extends ConsumerStatefulWidget {
  final bool accessDenied;
  const AdminLoginScreen({super.key, this.accessDenied = false});

  @override
  ConsumerState<AdminLoginScreen> createState() => _AdminLoginScreenState();
}

class _AdminLoginScreenState extends ConsumerState<AdminLoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _cafeName = TextEditingController();

  _Mode _mode = _Mode.signIn;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _cafeName.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final service = ref.read(authServiceProvider);
    if (service == null) return;

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      if (_mode == _Mode.signIn) {
        await service.signIn(email: _email.text.trim(), password: _password.text);
      } else {
        await service.signUpCafeAdmin(
          email: _email.text.trim(),
          password: _password.text,
          cafeName: _cafeName.text.trim(),
        );
      }
      if (mounted) context.go('/admin');
    } catch (e) {
      setState(() => _error = _friendlyError(e));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  String _friendlyError(Object e) {
    final message = e.toString();
    if (message.contains('Invalid login credentials')) return 'Incorrect email or password.';
    if (message.contains('already registered')) return 'An account with that email already exists.';
    return message.replaceFirst('Exception: ', '');
  }

  @override
  Widget build(BuildContext context) {
    return AdminThemeScope(
      child: Scaffold(
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: !Env.isSupabaseConfigured ? const _BackendNotConnected() : _buildForm(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildForm(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: adminSeedColor,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.storefront, color: Colors.white),
                  ),
                  const SizedBox(width: 12),
                  const Text('Café Admin', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _mode == _Mode.signIn ? 'Sign in to manage your café.' : 'Create your café\'s admin account.',
                style: const TextStyle(color: Colors.black54),
              ),
              const SizedBox(height: 24),
              if (widget.accessDenied)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: _Banner(
                    color: adminDanger,
                    text: 'That account does not have café admin access.',
                  ),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: _Banner(color: adminDanger, text: _error!),
                ),
              if (_mode == _Mode.signUp) ...[
                TextFormField(
                  controller: _cafeName,
                  decoration: const InputDecoration(labelText: 'Café name'),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: 12),
              ],
              TextFormField(
                controller: _email,
                decoration: const InputDecoration(labelText: 'Email'),
                keyboardType: TextInputType.emailAddress,
                validator: (v) => (v == null || !v.contains('@')) ? 'Enter a valid email' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _password,
                decoration: const InputDecoration(labelText: 'Password'),
                obscureText: true,
                validator: (v) =>
                    (v == null || v.length < 6) ? 'At least 6 characters' : null,
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _submitting ? null : _submit,
                child: _submitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : Text(_mode == _Mode.signIn ? 'Sign in' : 'Create account'),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: _submitting
                    ? null
                    : () => setState(() {
                          _mode = _mode == _Mode.signIn ? _Mode.signUp : _Mode.signIn;
                          _error = null;
                        }),
                child: Text(
                  _mode == _Mode.signIn
                      ? "New café? Create an account"
                      : 'Already have an account? Sign in',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  final Color color;
  final String text;
  const _Banner({required this.color, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text, style: TextStyle(color: color, fontSize: 13)),
    );
  }
}

class _BackendNotConnected extends StatelessWidget {
  const _BackendNotConnected();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.settings_suggest_outlined, size: 40),
            SizedBox(height: 16),
            Text('Backend not connected yet', style: TextStyle(fontWeight: FontWeight.w700)),
            SizedBox(height: 8),
            Text(
              'Add SUPABASE_URL and SUPABASE_ANON_KEY to app/.env to enable the café admin dashboard.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
