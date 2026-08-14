import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/admin_providers.dart';
import '../widgets/admin_states.dart';

class AdminSettingsScreen extends ConsumerStatefulWidget {
  const AdminSettingsScreen({super.key});

  @override
  ConsumerState<AdminSettingsScreen> createState() => _AdminSettingsScreenState();
}

class _AdminSettingsScreenState extends ConsumerState<AdminSettingsScreen> {
  final _nameController = TextEditingController();
  bool _saving = false;
  bool _loadedInitial = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final cafeId = ref.read(activeCafeIdProvider);
    if (cafeId == null) return;

    setState(() => _saving = true);
    try {
      await ref.read(cafeAdminRepositoryProvider).updateCafeName(cafeId, _nameController.text.trim());
      ref.invalidate(activeCafeProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved.')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cafeAsync = ref.watch(activeCafeProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: cafeAsync.when(
        loading: () => const AdminLoadingState(),
        error: (e, _) => AdminErrorState(message: 'Could not load café: $e'),
        data: (cafe) {
          if (cafe == null) {
            return const AdminEmptyState(
              icon: Icons.storefront_outlined,
              title: 'No café selected',
              message: 'Select a café from the sidebar first.',
            );
          }
          if (!_loadedInitial) {
            _nameController.text = cafe.name;
            _loadedInitial = true;
          }

          return SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('Café details', style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _nameController,
                        decoration: const InputDecoration(labelText: 'Café name'),
                      ),
                      const SizedBox(height: 20),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton(
                          onPressed: _saving ? null : _save,
                          child: _saving
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                )
                              : const Text('Save changes'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
