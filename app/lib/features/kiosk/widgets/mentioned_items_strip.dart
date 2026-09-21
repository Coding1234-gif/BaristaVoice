import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../models/menu.dart';

final _currency = NumberFormat.simpleCurrency(name: 'GBP');

/// Small "what the AI is talking about" cards shown below the conversation
/// panel — picture, name, short description and price — so an answer like
/// "we have a chocolate muffin" is visual, not just spoken.
///
/// Purely informational: these cards are NOT a second cart. They can't be
/// tapped and have no add/quantity controls — ordering stays voice-first,
/// and what the customer has actually ordered lives in the order summary.
/// Transcript = what the AI is saying; cards = what it's talking about;
/// order summary = what the customer has ordered.
///
/// Renders nothing when [itemIds] is empty or none of them are on [menu] (a
/// reply that wasn't about any specific item, or an id that isn't loaded), so
/// this never leaves an empty gap in the layout. Duplicate ids collapse into
/// one card, and at most [maxCards] are shown.
class MentionedItemsStrip extends StatelessWidget {
  static const maxCards = 4;

  final List<String> itemIds;
  final CafeMenu menu;

  const MentionedItemsStrip({
    super.key,
    required this.itemIds,
    required this.menu,
  });

  @override
  Widget build(BuildContext context) {
    final items = _resolve();
    final content = items.isEmpty
        ? const SizedBox(width: double.infinity)
        : _CardRow(items: items);

    // With "reduce motion" on, skip AnimatedSize altogether rather than
    // giving it a zero duration: a zero-length AnimatedSize finishes inside
    // its own layout pass, which Flutter asserts against.
    if (MediaQuery.disableAnimationsOf(context)) return content;

    // AnimatedSize eases the strip's height in/out as cards appear and
    // clear, instead of the content below it snapping.
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: content,
    );
  }

  /// Ids -> menu items, in the order the AI mentioned them. An id that isn't
  /// on the loaded menu is skipped silently; the menu stays the source of
  /// truth for every field shown.
  List<MenuItem> _resolve() {
    final seen = <String>{};
    final items = <MenuItem>[];
    for (final id in itemIds) {
      if (!seen.add(id)) continue;
      final item = menu.findById(id);
      if (item == null) continue;
      items.add(item);
      if (items.length == maxCards) break;
    }
    return items;
  }
}

Duration _animationDuration(BuildContext context, Duration normal) =>
    MediaQuery.disableAnimationsOf(context) ? Duration.zero : normal;

/// One card fills the row; several sit side by side and scroll sideways, so
/// a multi-item answer stays one card tall instead of a tall stack.
class _CardRow extends StatelessWidget {
  final List<MenuItem> items;
  const _CardRow({required this.items});

  static const _baseHeight = 96.0;

  @override
  Widget build(BuildContext context) {
    // Cards are a fixed height so a row of them lines up; grow it with the
    // user's text size so larger text doesn't overflow.
    final textScale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.6);
    final height = _baseHeight * textScale;

    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth.isFinite ? constraints.maxWidth : 340.0;
        final cardWidth = items.length == 1
            ? available.clamp(0.0, 420.0)
            : (available * 0.86).clamp(0.0, 320.0);

        // Flutter's default scroll behaviour only drags with touch, so on
        // web with a mouse a second card would be unreachable. Allow mouse
        // drag on this row only (dragging is scrolling, not tapping).
        return ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(
            dragDevices: {
              PointerDeviceKind.touch,
              PointerDeviceKind.mouse,
              PointerDeviceKind.stylus,
              PointerDeviceKind.trackpad,
            },
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0) const SizedBox(width: 10),
                  // Keyed by product id: a product that stays mentioned keeps
                  // its card as-is (no replay), only a newly mentioned one
                  // animates in.
                  _EntranceAnimation(
                    key: ValueKey(items[i].id),
                    child: SizedBox(
                      width: cardWidth,
                      height: height,
                      child: _ProductCard(item: items[i]),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Short fade + slight upward slide, played once when the card first
/// appears — quick and quiet so it never competes with the conversation.
class _EntranceAnimation extends StatelessWidget {
  final Widget child;
  const _EntranceAnimation({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: _animationDuration(context, const Duration(milliseconds: 240)),
      curve: Curves.easeOutCubic,
      child: child,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, (1 - t) * 10), child: child),
      ),
    );
  }
}

/// Deliberately has no InkWell/GestureDetector/buttons/chevron: it is a
/// read-only view of a [MenuItem].
class _ProductCard extends StatelessWidget {
  final MenuItem item;
  const _ProductCard({required this.item});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: Stack(
              children: [
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: _ItemImage(imageUrl: item.imageUrl, iconSize: 28),
                  ),
                ),
                if (item.popular)
                  const Positioned(top: 4, left: 4, child: _PopularBadge()),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                if (item.description.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    item.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  _currency.format(item.basePrice),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
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
