import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/admin_theme.dart';
import '../../../data/admin/admin_models.dart';
import '../../../state/admin_providers.dart';
import '../products/product_edit_dialog.dart';
import '../widgets/admin_states.dart';
import '../widgets/status_badge.dart';

class MenuManagementScreen extends ConsumerWidget {
  const MenuManagementScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final itemsAsync = ref.watch(menuItemsProvider);
    final uploadsAsync = ref.watch(menuUploadsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Menu'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: OutlinedButton.icon(
              onPressed: () => context.go('/admin/menu/upload'),
              icon: const Icon(Icons.upload_file_outlined, size: 18),
              label: const Text('Upload New Menu'),
            ),
          ),
        ],
      ),
      body: itemsAsync.when(
        loading: () => const AdminLoadingState(),
        error: (e, _) => AdminErrorState(
          message: 'Could not load your menu: $e',
          onRetry: () => ref.invalidate(menuItemsProvider),
        ),
        data: (items) {
          final drafts = items.where((r) => r.status == MenuItemStatus.draft).toList();

          return SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (drafts.isNotEmpty) _DraftReviewPanel(drafts: drafts),
                if (drafts.isNotEmpty) const SizedBox(height: 24),
                Text('Upload history', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                uploadsAsync.when(
                  loading: () => const AdminLoadingState(),
                  error: (e, _) => AdminErrorState(message: 'Could not load upload history: $e'),
                  data: (uploads) => uploads.isEmpty
                      ? const AdminEmptyState(
                          icon: Icons.history,
                          title: 'No uploads yet',
                          message: 'Upload a PDF or photo of your menu to get started.',
                        )
                      : Card(
                          child: Column(
                            children: [
                              for (final upload in uploads) _UploadRow(upload: upload),
                            ],
                          ),
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _DraftReviewPanel extends ConsumerWidget {
  final List<MenuItemRecord> drafts;
  const _DraftReviewPanel({required this.drafts});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cafeId = ref.watch(activeCafeIdProvider);

    return Card(
      color: adminWarning.withValues(alpha: 0.06),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.fact_check_outlined, color: adminWarning),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${drafts.length} product${drafts.length == 1 ? '' : 's'} detected. Review before publishing.',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            for (final record in drafts) _DraftRow(record: record),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              children: [
                OutlinedButton(
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Saved as draft. Customers cannot see these yet.')),
                    );
                  },
                  child: const Text('Save Draft'),
                ),
                FilledButton.icon(
                  onPressed: cafeId == null
                      ? null
                      : () async {
                          final count =
                              await ref.read(cafeAdminRepositoryProvider).publishAllDrafts(cafeId);
                          ref.invalidate(menuItemsProvider);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Published $count product${count == 1 ? '' : 's'}.')),
                            );
                          }
                        },
                  icon: const Icon(Icons.publish_outlined, size: 18),
                  label: const Text('Publish Menu'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DraftRow extends ConsumerWidget {
  final MenuItemRecord record;
  const _DraftRow({required this.record});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = record.item;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10)),
      child: ListTile(
        title: Text(item.name),
        subtitle: Text('${item.category} · \$${item.basePrice.toStringAsFixed(2)}'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 18),
              onPressed: () async {
                final updated =
                    await ProductEditDialog.show(context, initial: item, cafeId: record.cafeId);
                if (updated == null) return;
                await ref.read(cafeAdminRepositoryProvider).updateProduct(record.id, updated);
                ref.invalidate(menuItemsProvider);
              },
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 18),
              onPressed: () async {
                final confirmed = await showConfirmDialog(
                  context,
                  title: 'Discard ${item.name}?',
                  message: 'This removes it from the review list permanently.',
                );
                if (!confirmed) return;
                await ref.read(cafeAdminRepositoryProvider).deleteProduct(record.id);
                ref.invalidate(menuItemsProvider);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _UploadRow extends StatelessWidget {
  final MenuUpload upload;
  const _UploadRow({required this.upload});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (upload.status) {
      UploadStatus.structured => ('Processed', adminSuccess),
      UploadStatus.failed => ('Failed', adminDanger),
      UploadStatus.pending => ('Processing', adminWarning),
    };

    return ListTile(
      leading: Icon(
        upload.sourceType == 'pdf' ? Icons.picture_as_pdf_outlined : Icons.image_outlined,
        color: Colors.black45,
      ),
      title: Text(upload.sourceType == 'pdf' ? 'PDF menu' : 'Menu image'),
      subtitle: Text(DateFormat.yMMMd().add_jm().format(upload.createdAt.toLocal())),
      trailing: StatusBadge(label: label, color: color),
    );
  }
}
