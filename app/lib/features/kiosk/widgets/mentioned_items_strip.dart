import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../models/menu.dart';

final _currency = NumberFormat.simpleCurrency(name: 'GBP');

/// Small "what the AI is talking about" cards shown below the conversation
/// panel — picture, name, price, and a popular badge — so an answer like
/// "we have a chocolate muffin" is visual, not just spoken. Tapping a card
/// opens [_ItemDetailSheet] for the full description/options/add-to-order.
/// Renders nothing when [itemIds] is empty (a reply that wasn't about any
/// specific item), so this never leaves an empty gap in the layout.
class MentionedItemsStrip extends StatelessWidget {
  final List<String> itemIds;
  final CafeMenu menu;
  final void Function(MenuItem item) onAdd;

  const MentionedItemsStrip({
    super.key,
    required this.itemIds,
    required this.menu,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    final items = itemIds.map(menu.findById).whereType<MenuItem>().toList();
    if (items.isEmpty) return const SizedBox.shrink();

    return SizedBox(
      height: 168,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, i) => _ItemCard(
          item: items[i],
          onTap: () => _openDetail(context, items[i]),
        ),
      ),
    );
  }

  void _openDetail(BuildContext context, MenuItem item) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => _ItemDetailSheet(
        item: item,
        onAdd: () {
          onAdd(item);
          Navigator.of(context).pop();
        },
      ),
    );
  }
}

class _ItemCard extends StatelessWidget {
  final MenuItem item;
  final VoidCallback onTap;

  const _ItemCard({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SizedBox(
      width: 128,
      child: Material(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: SizedBox(
                        width: double.infinity,
                        height: 84,
                        child: _ItemImage(imageUrl: item.imageUrl, iconSize: 28),
                      ),
                    ),
                    if (item.popular)
                      Positioned(
                        top: 4,
                        left: 4,
                        child: _PopularBadge(),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                Text(
                  _currency.format(item.basePrice),
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ItemDetailSheet extends StatelessWidget {
  final MenuItem item;
  final VoidCallback onAdd;

  const _ItemDetailSheet({required this.item, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: theme.colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: SizedBox(
                width: double.infinity,
                height: 160,
                child: _ItemImage(imageUrl: item.imageUrl, iconSize: 48),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Text(item.name, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                ),
                if (item.popular) const Padding(padding: EdgeInsets.only(left: 8), child: _PopularBadge()),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              _currency.format(item.basePrice),
              style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.primary),
            ),
            if (item.description.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(item.description, style: theme.textTheme.bodyMedium),
            ],
            if (item.sizes.isNotEmpty) ...[
              const SizedBox(height: 12),
              _OptionsRow(label: 'Sizes', options: item.sizes.map((s) => s.name).toList()),
            ],
            if (item.milkOptions.isNotEmpty) ...[
              const SizedBox(height: 8),
              _OptionsRow(label: 'Milk', options: item.milkOptions.map((m) => m.name).toList()),
            ],
            if (item.modifiers.isNotEmpty) ...[
              const SizedBox(height: 8),
              _OptionsRow(label: 'Add-ons', options: item.modifiers.map((m) => m.name).toList()),
            ],
            if (item.allergens.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Contains: ${item.allergens.join(', ')}',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
              ),
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: item.available ? onAdd : null,
                icon: const Icon(Icons.add),
                label: Text(item.available ? 'Add to order' : 'Currently unavailable'),
                style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'You can still ask for a specific size, milk, or add-on by voice or typing.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _OptionsRow extends StatelessWidget {
  final String label;
  final List<String> options;
  const _OptionsRow({required this.label, required this.options});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final option in options)
              Chip(
                label: Text(option, style: const TextStyle(fontSize: 12)),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
          ],
        ),
      ],
    );
  }
}

class _ItemImage extends StatelessWidget {
  final String? imageUrl;
  final double iconSize;
  const _ItemImage({required this.imageUrl, required this.iconSize});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final url = imageUrl;

    if (url == null || url.isEmpty) return _placeholder(theme);
    return Image.network(
      url,
      fit: BoxFit.cover,
      errorBuilder: (context, error, stackTrace) => _placeholder(theme),
      loadingBuilder: (context, child, progress) => progress == null ? child : _placeholder(theme),
    );
  }

  Widget _placeholder(ThemeData theme) => Container(
        color: theme.colorScheme.surfaceContainerHighest,
        alignment: Alignment.center,
        child: Icon(Icons.local_cafe_outlined, size: iconSize, color: theme.colorScheme.onSurfaceVariant),
      );
}

class _PopularBadge extends StatelessWidget {
  const _PopularBadge();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.star, size: 10, color: theme.colorScheme.onPrimary),
          const SizedBox(width: 2),
          Text(
            'Popular',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onPrimary,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
