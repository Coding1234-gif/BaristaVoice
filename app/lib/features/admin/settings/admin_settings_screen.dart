import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../core/cafe_links.dart';
import '../../../core/qr_download/qr_download.dart';
import '../../../models/cafe.dart';
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Card(
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
                                      child:
                                          CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                    )
                                  : const Text('Save changes'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  _CafeQrSection(cafe: cafe),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The QR always encodes the café's permanent `cafes.id` — regenerating
/// this screen (or reloading it) never produces a different code, since
/// nothing here creates a new id. Scanning it (or opening the copied link)
/// takes a customer straight to this café's published menu, nothing else.
class _CafeQrSection extends StatefulWidget {
  final Cafe cafe;
  const _CafeQrSection({required this.cafe});

  @override
  State<_CafeQrSection> createState() => _CafeQrSectionState();
}

class _CafeQrSectionState extends State<_CafeQrSection> {
  final _qrBoundaryKey = GlobalKey();
  bool _downloading = false;

  Future<void> _copyLink() async {
    await Clipboard.setData(ClipboardData(text: CafeLinks.webUrl(widget.cafe.id)));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link copied.')));
    }
  }

  Future<void> _download() async {
    setState(() => _downloading = true);
    try {
      final boundary =
          _qrBoundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 4);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      final bytes = byteData!.buffer.asUint8List();
      downloadPngBytes(bytes, '${widget.cafe.name.replaceAll(' ', '_')}_qr_code.png');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not download QR code: $e')));
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final link = CafeLinks.webUrl(widget.cafe.id);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Your Café QR Code', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            const Text(
              'Print this at the counter or on tables. Customers who scan it go straight to '
              "this café's menu — the code never changes.",
              style: TextStyle(color: Colors.black54, fontSize: 13),
            ),
            const SizedBox(height: 20),
            Center(
              child: RepaintBoundary(
                key: _qrBoundaryKey,
                child: Container(
                  padding: const EdgeInsets.all(16),
                  color: Colors.white,
                  child: QrImageView(data: link, size: 200, backgroundColor: Colors.white),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Center(
              child: Text(widget.cafe.name, style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 20),
            SelectableText(
              link,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 12,
              runSpacing: 12,
              children: [
                OutlinedButton.icon(
                  onPressed: _copyLink,
                  icon: const Icon(Icons.link, size: 18),
                  label: const Text('Copy Link'),
                ),
                if (kIsWeb)
                  FilledButton.icon(
                    onPressed: _downloading ? null : _download,
                    icon: _downloading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.download, size: 18),
                    label: const Text('Download QR Code'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
