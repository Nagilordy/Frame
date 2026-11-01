// Touch layout pieces for phones: the same Frame look (colors, fonts, pills) in real phone
// sizes, for the screens that have a phone layout (see isPhone in ui.dart). Everything here is
// sized in the phone's own points, not the 1920x1080 TV canvas.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'images.dart';
import 'main.dart' show Jellyfin;
import 'ui.dart';

TextStyle phoneText(double size, {FontWeight weight = FontWeight.w600, Color color = kFg, double? height}) =>
    tvBody(size, weight: weight, color: color, height: height);
TextStyle phoneTitle(double size) => tvDisplay(size);

/// How many pixels wide to load a picture shown [points] wide on this phone.
int phoneDecode(BuildContext context, double points) =>
    sizeBucket((points * MediaQuery.devicePixelRatioOf(context)).ceil());

/// A light tap you can feel, on every press.
void phoneTap() => HapticFeedback.selectionClick();

// ---------- Buttons ----------

/// A round-ended button. [primary] is the white one (Play, Resume); the others are see-through grey.
class PhoneButton extends StatelessWidget {
  const PhoneButton({
    super.key,
    required this.onTap,
    this.label,
    this.icon,
    this.primary = false,
    this.height = 52,
    this.semanticLabel,
  });

  final VoidCallback onTap;
  final String? label;
  final IconData? icon;
  final bool primary;
  final double height;
  final String? semanticLabel; // for icon-only buttons

  @override
  Widget build(BuildContext context) {
    final fg = primary ? kBg : kFg;
    final iconOnly = label == null;
    return Semantics(
      button: true,
      label: semanticLabel ?? label,
      child: Material(
        color: primary ? kFg : const Color(0xBF4A4E57),
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            phoneTap();
            onTap();
          },
          child: SizedBox(
            height: height,
            width: iconOnly ? height : null,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: iconOnly ? 0 : 20),
              child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
                if (icon != null) Icon(icon, size: height * 0.46, color: fg),
                if (icon != null && !iconOnly) const SizedBox(width: 8),
                if (!iconOnly)
                  Flexible(
                    child: Text(label!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: phoneText(height >= 50 ? 17.0 : 15.0, weight: FontWeight.w700, color: fg)),
                  ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// The round avatar, top right: opens the profile menu.
class PhoneAvatar extends StatelessWidget {
  const PhoneAvatar({super.key, required this.name, required this.color, required this.onTap, this.size = 40});
  final String name;
  final Color color;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    final initial = name.isEmpty ? '?' : name.substring(0, 1).toUpperCase();
    return Semantics(
      button: true,
      label: '$name, switch profile',
      child: GestureDetector(
        onTap: () {
          phoneTap();
          onTap();
        },
        child: Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: Text(initial, style: phoneText(size * 0.42, weight: FontWeight.w700, color: kBg)),
        ),
      ),
    );
  }
}

// ---------- Library tabs ----------

/// Home + one pill per Jellyfin library, scrolling sideways so any number fits.
class PhoneTabs extends StatelessWidget {
  const PhoneTabs({
    super.key,
    required this.libraries,
    required this.currentId,
    required this.onHome,
    required this.onLibrary,
    this.padding = EdgeInsets.zero,
    this.height = 38,
  });

  final List<dynamic> libraries;
  final String? currentId; // null = Home
  final VoidCallback onHome;
  final void Function(dynamic library) onLibrary;
  final EdgeInsets padding;
  final double height;

  @override
  Widget build(BuildContext context) {
    Widget pill(String label, bool selected, VoidCallback onTap) => GestureDetector(
          onTap: selected
              ? null
              : () {
                  phoneTap();
                  onTap();
                },
          child: Container(
            height: height,
            padding: EdgeInsets.symmetric(horizontal: selected ? 16 : 14),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? const Color(0xEB2C313B) : Colors.transparent,
              borderRadius: BorderRadius.circular(height / 2),
            ),
            child: Text(label,
                style: phoneText(height >= 38 ? 15.0 : 14.0,
                    weight: selected ? FontWeight.w700 : FontWeight.w600, color: selected ? kFg : kSoft)),
          ),
        );
    return SizedBox(
      height: height,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: padding,
        children: [
          pill('Home', currentId == null, onHome),
          for (final lib in libraries) ...[
            const SizedBox(width: 4),
            pill((lib['Name'] ?? '').toString(), lib['Id']?.toString() == currentId, () => onLibrary(lib)),
          ],
        ],
      ),
    );
  }
}

// ---------- Progress ----------

class PhoneProgress extends StatelessWidget {
  const PhoneProgress({super.key, required this.value, this.height = 4, this.track = const Color(0x38F4F5F7)});
  final double value;
  final double height;
  final Color track;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: BoxDecoration(color: track, borderRadius: BorderRadius.circular(height)),
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: value.clamp(0.0, 1.0),
        child: Container(decoration: BoxDecoration(color: kFg, borderRadius: BorderRadius.circular(height))),
      ),
    );
  }
}

// ---------- A row of 16:9 cards ----------

/// A titled row of wide cards that scrolls sideways with a finger.
class PhoneMediaRow extends StatelessWidget {
  const PhoneMediaRow({
    super.key,
    required this.title,
    required this.items,
    required this.jf,
    required this.onTap,
    required this.padding,
    this.onLongPress,
    this.cardWidth = 236,
    this.showText = true,
  });

  final String title;
  final List<dynamic> items;
  final Jellyfin jf;
  final void Function(dynamic item) onTap;
  final void Function(dynamic item)? onLongPress;
  final EdgeInsets padding; // left / right margins of the row
  final double cardWidth;
  final bool showText;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final cardH = cardWidth * 9 / 16;
    final decode = phoneDecode(context, cardWidth);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: EdgeInsets.only(left: padding.left, right: padding.right, bottom: 12),
        child: Text(title, style: phoneText(19, weight: FontWeight.w700)),
      ),
      SizedBox(
        height: cardH + (showText ? 52 : 0),
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.only(left: padding.left, right: padding.right),
          itemCount: items.length,
          separatorBuilder: (_, __) => const SizedBox(width: 12),
          itemBuilder: (context, i) {
            final item = items[i];
            final progress = progressOf(item);
            final ep = episodeLine(item);
            final meta = [
              if (ep.isNotEmpty) ep.split(' · ').take(2).join(' · '),
              if (progress > 0) '${minutesLeft(item)} min left',
            ].join(' · ').toUpperCase();
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                phoneTap();
                onTap(item);
              },
              onLongPress: onLongPress == null
                  ? null
                  : () {
                      HapticFeedback.mediumImpact();
                      onLongPress!(item);
                    },
              child: SizedBox(
                width: cardWidth,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      width: cardWidth,
                      height: cardH,
                      child: Stack(fit: StackFit.expand, children: [
                        netImage(
                          jf.thumbFor(item, maxWidth: decode),
                          cacheWidth: decode,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => const ColoredBox(color: kPlaceholder),
                        ),
                        if (progress > 0)
                          Positioned(
                            left: 10,
                            right: 10,
                            bottom: 10,
                            child: PhoneProgress(value: progress, track: const Color(0x8C06080B)),
                          ),
                      ]),
                    ),
                  ),
                  if (showText) ...[
                    const SizedBox(height: 8),
                    if (meta.isNotEmpty)
                      Text(meta,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: phoneText(11.5, weight: FontWeight.w700, color: kMuted)),
                    const SizedBox(height: 3),
                    Text(titleOf(item),
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: phoneText(15, weight: FontWeight.w600)),
                  ],
                ]),
              ),
            );
          },
        ),
      ),
    ]);
  }
}
