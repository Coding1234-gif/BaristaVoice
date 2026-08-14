import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/admin/admin_models.dart';
import '../../../state/admin_providers.dart';
import '../widgets/admin_states.dart';
import '../widgets/status_badge.dart';
import 'product_edit_dialog.dart';

class ProductsScreen extends ConsumerWidget {
  const ProductsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cafeId = ref.watch(activeCafeIdProvider);
    final itemsAsync = ref.watch(menuItemsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Products'),
        actions: [
          if (cafeId != null)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: FilledButton.icon(
                onPressed: () async {
                  final created = await ProductEditDialog.show(context, cafeId: cafeId);
                  if (created == null) return;
                  await ref.read(cafeAdminRepositoryProvider).addProduct(cafeId, created, publish: true);
                  ref.invalidate(menuItemsProvider);
                },
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add product'),
              ),
            ),
        ],
      ),
      body: itemsAsync.when(
        loading: () => const AdminLoadingState(),
        error: (e, _) => AdminErrorState(
          message: 'Could not load products: $e',
          onRetry: () => ref.invalidate(menuItemsProvider),
        ),
        data: (items) {
          if (items.isEmpty) {
            return AdminEmptyState(
              icon: Icons.local_cafe_outlined,
              title: 'No products yet',
              message: 'Upload a menu or add your first product manually.',
              action: cafeId == null
                  ? null
                  : FilledButton.icon(
                      onPressed: () async {
                        final created = await ProductEditDialog.show(context, cafeId: cafeId);
                        if (created == null) return;
                        await ref.read(cafeAdminRepositoryProvider).addProduct(cafeId, created, publish: true);
                        ref.invalidate(menuItemsProvider);
                      },
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add product'),
                    ),
            );
          }

          return GridView.builder(
            padding: const EdgeInsets.all(24),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 340,
              mainAxisExtent: 280,
              crossAxisSpacing: 16,
              mainAxisSpacing: 16,
            ),
            itemCount: items.length,
            itemBuilder: (context, i) => _ProductCard(record: items[i]),
          );
        },
      ),
    );
  }
}

class _ProductCard extends ConsumerWidget {
  final MenuItemRecord record;
  const _ProductCard({required this.record});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = record.item;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: item.imageUrl != null
                ? Image.network(item.imageUrl!, fit: BoxFit.cover)
                : Container(
                    color: const Color(0xFFF2F2F7),
                    child: const Icon(Icons.local_cafe_outlined, color: Colors.black26, size: 32),
                  ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.name,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text('\$${item.basePrice.toStringAsFixed(2)}',
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    item.description.isEmpty ? item.category : item.description,
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const Spacer(),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      record.status == MenuItemStatus.published
                          ? StatusBadge.published()
                          : StatusBadge.draft(),
                      if (!item.available) StatusBadge.unavailable(),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Row(
            children: [
              Expanded(
                child: TextButton.icon(
                  onPressed: () async {
                    final updated = await ProductEditDialog.show(
                      context,
                      initial: item,
                      cafeId: record.cafeId,
                    );
                    if (updated == null) return;
                    await ref.read(cafeAdminRepositoryProvider).updateProduct(record.id, updated);
                    ref.invalidate(menuItemsProvider);
                  },
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  label: const Text('Edit'),
                ),
              ),
              IconButton(
                tooltip: record.status == MenuItemStatus.published ? 'Unpublish' : 'Publish',
                icon: Icon(
                  record.status == MenuItemStatus.published
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 18,
                ),
                onPressed: () async {
                  final next = record.status == MenuItemStatus.published
                      ? MenuItemStatus.draft
                      : MenuItemStatus.published;
                  await ref.read(cafeAdminRepositoryProvider).setStatus(record.id, next);
                  ref.invalidate(menuItemsProvider);
                },
              ),
              IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline, size: 18),
                onPressed: () async {
                  final confirmed = await showConfirmDialog(
                    context,
                    title: 'Delete ${item.name}?',
                    message: 'This removes it from your menu permanently. Customers will no longer see it.',
                  );
                  if (!confirmed) return;
                  await ref.read(cafeAdminRepositoryProvider).deleteProduct(record.id);
                  ref.invalidate(menuItemsProvider);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
