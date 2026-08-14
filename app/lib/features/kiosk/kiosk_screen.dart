import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/env.dart';
import '../../models/cafe.dart';
import '../../models/menu.dart';
import '../../state/cafe_providers.dart';
import '../../state/kiosk_controller.dart';
import '../../state/providers.dart';
import 'widgets/conversation_panel.dart';
import 'widgets/mic_button.dart';
import 'widgets/order_summary_panel.dart';

class KioskScreen extends ConsumerWidget {
  const KioskScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cafeId = ref.watch(currentCafeIdProvider);

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            if (!Env.isSupabaseConfigured)
              const _BackendNotConnected()
            else if (cafeId == null)
              const _NoCafeSelected()
            else
              _CafeLoader(cafeId: cafeId),
            const Positioned(top: 4, right: 12, child: _ForCafesLink()),
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

class _BackendNotConnected extends StatelessWidget {
  const _BackendNotConnected();

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
            Text('Backend not connected yet', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text(
              'Add SUPABASE_URL and SUPABASE_ANON_KEY to app/.env, deploy the '
              'order-agent Edge Function, and restart the app to enable '
              'conversational ordering.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// No café in currentCafeIdProvider — the ONLY state customers ever land in
/// before scanning. Never silently substitutes the demo café or any other
/// menu; "View demo café" below is an explicit tap, not a fallback.
class _NoCafeSelected extends ConsumerStatefulWidget {
  const _NoCafeSelected();

  @override
  ConsumerState<_NoCafeSelected> createState() => _NoCafeSelectedState();
}

class _NoCafeSelectedState extends ConsumerState<_NoCafeSelected> {
  final _controller = TextEditingController();
  bool _resolving = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit(String rawInput) async {
    final idOrSlug = extractCafeIdOrSlug(rawInput);
    if (idOrSlug.isEmpty) return;

    setState(() {
      _resolving = true;
      _error = null;
    });

    try {
      final cafe = await resolveAndSelectCafe(ref, idOrSlug);
      if (!mounted) return;
      if (cafe == null) {
        setState(() => _error = "Sorry, we couldn't find this café.");
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Something went wrong. Check your connection.');
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.qr_code_scanner, size: 56),
              const SizedBox(height: 20),
              Text(
                "Scan a café's QR code to view its menu.",
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              const Text(
                'Look for the QR code at the counter or on the table.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.black54),
              ),
              const SizedBox(height: 28),
              TextField(
                controller: _controller,
                enabled: !_resolving,
                decoration: const InputDecoration(
                  labelText: 'Or enter a café code / link',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: _submit,
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 13)),
              ],
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _resolving ? null : () => _submit(_controller.text),
                child: _resolving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('Go'),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: _resolving ? null : () => _submit('demo'),
                child: const Text('View demo café'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Loads the currently-selected café's details, then its menu once the café
/// itself resolves. Everything below this point in the widget tree is
/// scoped to [cafeId] — no other part of the customer app independently
/// decides which café's data to show.
class _CafeLoader extends ConsumerWidget {
  final String cafeId;
  const _CafeLoader({required this.cafeId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cafeAsync = ref.watch(currentCafeProvider);

    return cafeAsync.when(
      loading: () => const _CenteredMessage(child: CircularProgressIndicator()),
      error: (e, _) => _CenteredMessage(
        child: _ErrorState(
          message: 'Something went wrong loading this café.',
          onRetry: () => ref.invalidate(currentCafeProvider),
        ),
      ),
      data: (cafe) {
        if (cafe == null) {
          // A previously-selected café no longer exists (e.g. deleted).
          return _CenteredMessage(
            child: _ErrorState(
              message: "Sorry, we couldn't find this café anymore.",
              onRetry: () => ref.read(currentCafeIdProvider.notifier).clear(),
              retryLabel: 'Scan a different café',
            ),
          );
        }
        return _CafeBody(cafe: cafe);
      },
    );
  }
}

class _CafeBody extends ConsumerWidget {
  final Cafe cafe;
  const _CafeBody({required this.cafe});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final menuAsync = ref.watch(activeMenuProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CafeHeader(cafe: cafe),
        Expanded(
          child: menuAsync.when(
            loading: () => _CenteredMessage(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text("Loading ${cafe.name}'s menu…"),
                ],
              ),
            ),
            error: (e, _) => _CenteredMessage(
              child: _ErrorState(
                message: 'Something went wrong loading the menu.',
                onRetry: () => ref.invalidate(activeMenuProvider),
              ),
            ),
            data: (menu) {
              if (menu == null || menu.items.isEmpty) {
                return _CenteredMessage(
                  child: _ErrorState(
                    icon: Icons.menu_book_outlined,
                    message: "This café hasn't published its menu yet.",
                  ),
                );
              }
              return _KioskBody(menu: menu);
            },
          ),
        ),
      ],
    );
  }
}

class _CafeHeader extends ConsumerWidget {
  final Cafe cafe;
  const _CafeHeader({required this.cafe});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 40, 20, 8),
      child: Row(
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
            backgroundImage: cafe.logoUrl != null ? NetworkImage(cafe.logoUrl!) : null,
            child: cafe.logoUrl == null
                ? Icon(Icons.storefront, color: Theme.of(context).colorScheme.primary)
                : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(cafe.name, style: Theme.of(context).textTheme.titleLarge),
                Text(
                  'AI-powered menu',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.black54),
                ),
              ],
            ),
          ),
          const _ListeningDot(),
          TextButton(
            onPressed: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Change café?'),
                  content: Text('You are currently viewing ${cafe.name}.'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      child: const Text('Change café'),
                    ),
                  ],
                ),
              );
              if (confirmed == true) {
                await ref.read(currentCafeIdProvider.notifier).clear();
              }
            },
            child: const Text('Change'),
          ),
        ],
      ),
    );
  }
}

class _CenteredMessage extends StatelessWidget {
  final Widget child;
  const _CenteredMessage({required this.child});

  @override
  Widget build(BuildContext context) => Center(child: Padding(padding: const EdgeInsets.all(24), child: child));
}

class _ErrorState extends StatelessWidget {
  final String message;
  final IconData icon;
  final VoidCallback? onRetry;
  final String retryLabel;

  const _ErrorState({
    required this.message,
    this.icon = Icons.error_outline,
    this.onRetry,
    this.retryLabel = 'Try again',
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 40, color: Colors.black45),
        const SizedBox(height: 12),
        Text(message, textAlign: TextAlign.center),
        if (onRetry != null) ...[
          const SizedBox(height: 16),
          OutlinedButton(onPressed: onRetry, child: Text(retryLabel)),
        ],
      ],
    );
  }
}

/// The order summary panel stays pinned below the scrollable
/// conversation/mic area, like a persistent cart bar — unchanged from the
/// original layout, just no longer carrying its own café-name header row
/// (that's now _CafeHeader, shown once above regardless of menu state).
class _KioskBody extends ConsumerWidget {
  final CafeMenu menu;
  const _KioskBody({required this.menu});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kioskState = ref.watch(kioskControllerProvider);
    final controller = ref.read(kioskControllerProvider.notifier);

    return Column(
      children: [
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
      mainAxisSize: MainAxisSize.min,
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
        Text(isLive ? 'Live' : 'Idle', style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }
}
