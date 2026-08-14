import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../state/cafe_providers.dart';

/// The QR/deep-link landing route: `/cafe/:cafeId`. This is the ONLY place a
/// café is entered from a link — it resolves the id/slug against the
/// database (never trusts it blindly), and only on success updates the
/// single current-café source of truth before handing off to the kiosk
/// screen. An invalid id shows a friendly error instead of crashing or
/// silently falling back to any other café.
class CafeEntryScreen extends ConsumerStatefulWidget {
  final String cafeIdOrSlug;
  const CafeEntryScreen({super.key, required this.cafeIdOrSlug});

  @override
  ConsumerState<CafeEntryScreen> createState() => _CafeEntryScreenState();
}

enum _Status { loading, notFound, error }

class _CafeEntryScreenState extends ConsumerState<CafeEntryScreen> {
  _Status _status = _Status.loading;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _resolve());
  }

  Future<void> _resolve() async {
    try {
      final cafe = await resolveAndSelectCafe(ref, widget.cafeIdOrSlug);
      if (!mounted) return;
      if (cafe == null) {
        setState(() => _status = _Status.notFound);
      } else {
        context.go('/');
      }
    } catch (e) {
      debugPrint('[cafe_entry] resolveAndSelectCafe(${widget.cafeIdOrSlug}) failed: $e');
      if (mounted) setState(() => _status = _Status.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: switch (_status) {
            _Status.loading => const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Finding your café…'),
                ],
              ),
            _Status.notFound => _ErrorCard(
                icon: Icons.search_off,
                message: "Sorry, we couldn't find this café.",
              ),
            _Status.error => _ErrorCard(
                icon: Icons.wifi_off,
                message: 'Something went wrong. Check your connection and try again.',
              ),
          },
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final IconData icon;
  final String message;
  const _ErrorCard({required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 40, color: Colors.black45),
        const SizedBox(height: 16),
        Text(message, textAlign: TextAlign.center),
        const SizedBox(height: 20),
        FilledButton(onPressed: () => context.go('/'), child: const Text('Go home')),
      ],
    );
  }
}
