import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/env.dart';
import '../../models/menu.dart';
import '../../state/kiosk_controller.dart';
import '../../state/providers.dart';
import 'widgets/conversation_panel.dart';
import 'widgets/mic_button.dart';
import 'widgets/order_summary_panel.dart';

class KioskScreen extends ConsumerWidget {
  const KioskScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final menuAsync = ref.watch(activeMenuProvider);

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            menuAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Could not load menu: $e')),
              data: (menu) {
                if (!Env.isSupabaseConfigured) {
                  return _SetupNeeded(menu: menu);
                }
                return _KioskBody(menu: menu);
              },
            ),
            const Positioned(top: 44, right: 12, child: _ForCafesLink()),
          ],
        ),
      ),
    );
  }
}

/// The dashboard's only entry point from the customer app: small and easy to
/// miss on purpose, since this screen is for customers, not café owners.
/// Routing (and the backend RLS behind it) is what actually keeps a
/// customer who taps this — or types /admin directly — out of the admin
/// dashboard; this is just a convenience link.
class _ForCafesLink extends StatelessWidget {
  const _ForCafesLink();

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () => context.go('/admin/login'),
      style: TextButton.styleFrom(
        foregroundColor: Colors.black45,
        textStyle: const TextStyle(fontSize: 12),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      ),
      child: const Text('For Cafés'),
    );
  }
}

class _SetupNeeded extends StatelessWidget {
  final CafeMenu menu;
  const _SetupNeeded({required this.menu});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.settings_suggest_outlined, size: 48),
            const SizedBox(height: 16),
            Text(
              'Backend not connected yet',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text(
              'Add SUPABASE_URL and SUPABASE_ANON_KEY to app/.env, deploy the '
              'order-agent Edge Function, and restart the app to enable '
              'conversational ordering.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Text('Menu loaded: ${menu.items.length} items from ${menu.cafeName}.',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _KioskBody extends ConsumerWidget {
  final CafeMenu menu;
  const _KioskBody({required this.menu});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kioskState = ref.watch(kioskControllerProvider);
    final controller = ref.read(kioskControllerProvider.notifier);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(menu.cafeName, style: Theme.of(context).textTheme.headlineSmall),
              const _ListeningDot(),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            child: Column(
              children: [
                ConversationPanel(
                  liveTranscript: kioskState.liveTranscript,
                  assistantReply: kioskState.assistantReply,
                  errorMessage: kioskState.errorMessage,
                  isListening: kioskState.listeningStatus == ListeningStatus.listening,
                ),
                const SizedBox(height: 32),
                MicButton(
                  status: kioskState.listeningStatus,
                  onTap: controller.startListening,
                ),
              ],
            ),
          ),
        ),
        OrderSummaryPanel(
          order: kioskState.order,
          menu: menu,
          onConfirm: controller.confirmOrder,
        ),
      ],
    );
  }
}

class _ListeningDot extends ConsumerWidget {
  const _ListeningDot();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(kioskControllerProvider).listeningStatus;
    final isLive = status != ListeningStatus.idle;
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isLive ? Colors.redAccent : Colors.grey,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          isLive ? 'Live' : 'Idle',
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ],
    );
  }
}
