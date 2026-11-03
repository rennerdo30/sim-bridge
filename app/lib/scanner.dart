import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'l10n/app_localizations.dart';
import 'theme.dart';

const _invitePrefix = 'simbridge://invite#';

class InviteScanner extends StatefulWidget {
  const InviteScanner({super.key});
  @override
  State<InviteScanner> createState() => _InviteScannerState();
}

class _InviteScannerState extends State<InviteScanner> {
  bool found = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: Palette.board,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: Text(
          l10n.scanTitle,
          style: display(size: 19, color: Colors.white),
        ),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            onDetect: (capture) {
              if (found) return;
              final value = capture.barcodes.firstOrNull?.rawValue;
              if (value?.startsWith(_invitePrefix) != true) return;
              found = true;
              Navigator.pop(context, value);
            },
          ),
          Center(
            child: Container(
              width: 270,
              height: 270,
              decoration: ShapeDecoration(
                shape: simShape(
                  cut: 44,
                  base: 16,
                  side: const BorderSide(color: Palette.chip, width: 3),
                ),
              ),
            ),
          ),
          Positioned(
            left: 30,
            right: 30,
            bottom: 54,
            child: Text(
              l10n.scanHint,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
