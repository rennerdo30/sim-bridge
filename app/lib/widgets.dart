import 'package:flutter/material.dart';

import 'theme.dart';
import 'sensitive_clipboard.dart';

/// Small translucent pill used on dark surfaces (onboarding hero).
class TrustPill extends StatelessWidget {
  const TrustPill({super.key, required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    decoration: ShapeDecoration(
      color: Colors.white.withValues(alpha: .08),
      shape: simShape(
        cut: 14,
        base: 5,
        side: BorderSide(color: Colors.white.withValues(alpha: .14)),
      ),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: Palette.chip),
        const SizedBox(width: 6),
        Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

/// Segmented role selector (gateway / client) on Android onboarding.
class ModeButton extends StatelessWidget {
  const ModeButton({
    super.key,
    required this.selected,
    required this.icon,
    required this.text,
    required this.onTap,
  });
  final bool selected;
  final IconData icon;
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: selected ? Palette.card : Colors.transparent,
    shape: simShape(
      cut: 12,
      base: 5,
      side: selected
          ? const BorderSide(color: Palette.chip, width: 1.4)
          : BorderSide.none,
    ),
    child: InkWell(
      customBorder: simShape(cut: 12, base: 5),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 13),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: selected ? Palette.ink : Palette.haze),
            const SizedBox(width: 7),
            Text(
              text,
              style: TextStyle(
                color: selected ? Palette.ink : Palette.haze,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// The hero of the Activity tab: the bridge presented as the SIM itself —
/// a dark board-green card with the signature chamfer and the gold chip.
class LineCard extends StatelessWidget {
  const LineCard({
    super.key,
    required this.online,
    required this.statusText,
    required this.detailText,
    required this.metrics,
  });
  final bool online;
  final String statusText;
  final String detailText;
  final List<(String value, String label)> metrics;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(22, 20, 22, 20),
    decoration: ShapeDecoration(
      shape: simShape(),
      gradient: const LinearGradient(
        colors: [Palette.board, Palette.boardRaised],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const ChipContactMark(size: 30),
            const Spacer(),
            Container(
              width: 9,
              height: 9,
              margin: const EdgeInsets.only(top: 4, right: 7),
              decoration: BoxDecoration(
                color: online ? Palette.chip : Palette.fault,
                shape: BoxShape.circle,
              ),
            ),
            Text(
              statusText,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 22),
        Text(detailText, style: mono(size: 12.5, color: Colors.white70)),
        const SizedBox(height: 18),
        Row(
          children: [
            for (final (index, metric) in metrics.indexed) ...[
              if (index > 0) const SizedBox(width: 36),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    metric.$1,
                    style: display(size: 19, color: Colors.white),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    metric.$2.toUpperCase(),
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: .45),
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ],
    ),
  );
}

/// Compact metadata pill on event cards (gateway, SIM, number).
class MetaChip extends StatelessWidget {
  const MetaChip({super.key, required this.text, this.monospace = false});
  final String text;
  final bool monospace;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: Palette.porcelain,
      borderRadius: BorderRadius.circular(7),
      border: Border.all(color: Palette.line),
    ),
    child: Text(
      text,
      style: monospace
          ? mono(size: 10.5, color: Palette.haze)
          : const TextStyle(
              color: Palette.haze,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
            ),
    ),
  );
}

/// Prominent verification-code block: gold, chamfered, one-tap copy.
class OtpBlock extends StatelessWidget {
  const OtpBlock({
    super.key,
    required this.code,
    required this.label,
    required this.copiedMessage,
  });
  final String code;
  final String label;
  final String copiedMessage;

  @override
  Widget build(BuildContext context) => Material(
    color: Palette.chipSoft,
    shape: simShape(
      cut: 16,
      base: 6,
      side: const BorderSide(color: Palette.chip),
    ),
    child: InkWell(
      customBorder: simShape(cut: 16, base: 6),
      onTap: () async {
        await copySensitiveText(code);
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(copiedMessage)));
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label.toUpperCase(),
                    style: const TextStyle(
                      color: Palette.fir,
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.1,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    code,
                    style: mono(
                      size: 22,
                      weight: FontWeight.w700,
                      color: Palette.ink,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.copy_rounded, size: 19, color: Palette.fir),
          ],
        ),
      ),
    ),
  );
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
  });
  final IconData icon;
  final String title, body;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 46),
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            alignment: Alignment.center,
            decoration: ShapeDecoration(
              color: Palette.porcelain,
              shape: simShape(cut: 22, base: 9),
            ),
            child: Icon(icon, color: Palette.fir, size: 28),
          ),
          const SizedBox(height: 16),
          Text(title, style: display(size: 17)),
          const SizedBox(height: 7),
          Text(
            body,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Palette.haze, height: 1.4),
          ),
        ],
      ),
    ),
  );
}

class ErrorBanner extends StatelessWidget {
  const ErrorBanner({super.key, required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: ShapeDecoration(
      color: Palette.faultSoft,
      shape: simShape(cut: 14, base: 6),
    ),
    child: Row(
      children: [
        const Icon(Icons.error_outline, color: Palette.fault, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            message,
            style: const TextStyle(color: Palette.fault, fontSize: 13),
          ),
        ),
      ],
    ),
  );
}

class Sheet extends StatelessWidget {
  const Sheet({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      decoration: const BoxDecoration(
        color: Palette.porcelain,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 38,
              height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: Palette.line,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            child,
          ],
        ),
      ),
    ),
  );
}

class SheetHeader extends StatelessWidget {
  const SheetHeader({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
  });
  final IconData icon;
  final String title, subtitle;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(
        width: 48,
        height: 48,
        alignment: Alignment.center,
        decoration: ShapeDecoration(
          color: Palette.chipSoft,
          shape: simShape(cut: 17, base: 7),
        ),
        child: Icon(icon, color: Palette.ink),
      ),
      const SizedBox(width: 14),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: display(size: 20)),
            const SizedBox(height: 3),
            Text(
              subtitle,
              style: const TextStyle(color: Palette.haze, fontSize: 13),
            ),
          ],
        ),
      ),
    ],
  );
}

class ActionTile extends StatelessWidget {
  const ActionTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final String title, subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Palette.card,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(Corners.card),
      side: const BorderSide(color: Palette.line),
    ),
    child: InkWell(
      borderRadius: BorderRadius.circular(Corners.card),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Row(
          children: [
            Icon(icon, color: Palette.fir),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: const TextStyle(color: Palette.haze, fontSize: 12),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Palette.haze),
          ],
        ),
      ),
    ),
  );
}

/// Read-only secret (recovery code, relay URL) with one-tap copy.
class SecretField extends StatelessWidget {
  const SecretField({
    super.key,
    required this.label,
    required this.value,
    required this.copiedMessage,
    required this.copyTooltip,
  });
  final String label, value, copiedMessage, copyTooltip;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
    decoration: BoxDecoration(
      color: Palette.card,
      borderRadius: BorderRadius.circular(Corners.field),
      border: Border.all(color: Palette.line),
    ),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label.toUpperCase(),
                style: const TextStyle(
                  color: Palette.haze,
                  fontSize: 9.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: .8,
                ),
              ),
              const SizedBox(height: 4),
              Text(value, style: mono(size: 12, weight: FontWeight.w700)),
            ],
          ),
        ),
        IconButton(
          tooltip: copyTooltip,
          onPressed: () async {
            await copySensitiveText(value);
            if (!context.mounted) return;
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(copiedMessage)));
          },
          icon: const Icon(Icons.copy_rounded, size: 19, color: Palette.fir),
        ),
      ],
    ),
  );
}

/// One phone in the bridge, with its presence, SIMs, and — for the owner
/// device only — the control to remove it.
class DeviceCard extends StatelessWidget {
  const DeviceCard({
    super.key,
    required this.name,
    required this.statusLine,
    required this.isGateway,
    required this.online,
    required this.isCurrentDevice,
    required this.isOwner,
    required this.currentDeviceLabel,
    required this.ownerLabel,
    required this.simChips,
    required this.removeLabel,
    this.isComputer = false,
    this.onRemove,
  });

  final String name;
  final String statusLine;
  final bool isGateway;
  final bool online;
  final bool isCurrentDevice;

  /// Shows a computer instead of a phone; the roster carries no device kind,
  /// so callers know this only for the current device.
  final bool isComputer;
  final bool isOwner;
  final String currentDeviceLabel;
  final String ownerLabel;
  final List<String> simChips;
  final String removeLabel;

  /// Null hides the control entirely — a phone that may not remove this
  /// device should not be shown a button that will fail.
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    alignment: Alignment.center,
                    decoration: ShapeDecoration(
                      color: isGateway ? Palette.board : Palette.porcelain,
                      shape: simShape(cut: 16, base: 7),
                    ),
                    child: isGateway
                        ? const ChipContactMark(size: 22)
                        : Icon(
                            isComputer
                                ? Icons.desktop_windows_outlined
                                : Icons.smartphone,
                            color: Palette.ink,
                          ),
                  ),
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: Container(
                      width: 13,
                      height: 13,
                      decoration: BoxDecoration(
                        color: online ? Palette.signal : Palette.haze,
                        shape: BoxShape.circle,
                        border: Border.all(color: Palette.card, width: 2),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            overflow: TextOverflow.ellipsis,
                            style: display(size: 16),
                          ),
                        ),
                        if (isCurrentDevice)
                          _Badge(text: currentDeviceLabel, color: Palette.chip),
                        if (isOwner)
                          _Badge(text: ownerLabel, color: Palette.haze),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      statusLine,
                      style: const TextStyle(color: Palette.haze, fontSize: 13),
                    ),
                  ],
                ),
              ),
              if (onRemove != null)
                TextButton(
                  onPressed: onRemove,
                  style: TextButton.styleFrom(
                    foregroundColor: Palette.fault,
                    textStyle: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  child: Text(removeLabel),
                ),
            ],
          ),
          if (simChips.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final chip in simChips)
                  MetaChip(text: chip, monospace: true),
              ],
            ),
          ],
        ],
      ),
    ),
  );
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 7),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        color: color,
        fontSize: 9,
        fontWeight: FontWeight.w900,
        letterSpacing: .6,
      ),
    ),
  );
}

/// A consequence the reader should absorb before confirming something.
class RemovalNote extends StatelessWidget {
  const RemovalNote({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(13),
    decoration: ShapeDecoration(
      color: Palette.card,
      shape: simShape(
        cut: 15,
        base: 6,
        side: const BorderSide(color: Palette.line),
      ),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.info_outline, size: 17, color: Palette.haze),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              color: Palette.haze,
              fontSize: 12.5,
              height: 1.4,
            ),
          ),
        ),
      ],
    ),
  );
}

class SettingsTile extends StatelessWidget {
  const SettingsTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.onTap,
    this.destructive = false,
  });
  final IconData icon;
  final String title, subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) => ListTile(
    onTap: onTap,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
    leading: Icon(icon, color: destructive ? Palette.fault : Palette.fir),
    title: Text(
      title,
      style: TextStyle(
        fontWeight: FontWeight.w700,
        color: destructive ? Palette.fault : Palette.ink,
      ),
    ),
    // Explanations wrap: German and narrow phones would otherwise cut
    // the sentence that tells the user what the setting does.
    subtitle: Text(
      subtitle,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(color: Palette.haze, fontSize: 12),
    ),
    trailing:
        trailing ?? (onTap != null ? const Icon(Icons.chevron_right) : null),
  );
}

class OnlineLabel extends StatelessWidget {
  const OnlineLabel({super.key, required this.online, required this.text});
  final bool online;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: online ? Palette.signalSoft : Palette.porcelain,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: online ? Palette.signal : Palette.line),
    ),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        color: online ? Palette.signal : Palette.haze,
        fontSize: 9,
        fontWeight: FontWeight.w900,
        letterSpacing: .7,
      ),
    ),
  );
}
