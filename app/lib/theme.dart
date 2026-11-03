import 'package:flutter/material.dart';

/// Sim Bridge design tokens.
///
/// The visual language borrows its materials from the SIM card itself:
/// porcelain plastic, a deep circuit-board green, and the gold contact chip.
/// The signature shape is the SIM chamfer — one cut corner, the notch that
/// keeps a SIM from being inserted the wrong way. It appears only on
/// SIM-related surfaces; everything else stays quietly rounded.
abstract final class Palette {
  static const porcelain = Color(0xffF5F3EC);
  static const board = Color(0xff0E1B16);
  static const boardRaised = Color(0xff1E3A30);
  static const fir = Color(0xff24443A);
  static const chip = Color(0xffD9A13F);
  static const chipSoft = Color(0xffF4E7C8);
  static const ink = Color(0xff16211D);
  static const haze = Color(0xff6A736D);
  static const line = Color(0xffE3E0D4);
  static const card = Colors.white;
  static const signal = Color(0xff2E7D4F);
  static const signalSoft = Color(0xffE3F0E5);
  static const fault = Color(0xffB03B2E);
  static const faultSoft = Color(0xffF9E9E4);
}

abstract final class Fonts {
  static const display = 'Bricolage';
  static const mono = 'JetBrainsMono';
}

/// Corner radii. [simCut] is the signature chamfer; [bevel] is the quiet
/// cut used on buttons so the whole system shares one geometry.
abstract final class Corners {
  static const simCut = 26.0;
  static const simBase = 10.0;
  static const bevel = 9.0;
  static const card = 16.0;
  static const field = 12.0;
}

/// The SIM chamfer: one large cut corner, three small ones.
BeveledRectangleBorder simShape({
  double cut = Corners.simCut,
  double base = Corners.simBase,
  BorderSide side = BorderSide.none,
}) => BeveledRectangleBorder(
  side: side,
  borderRadius: BorderRadius.only(
    topLeft: Radius.circular(base),
    topRight: Radius.circular(cut),
    bottomLeft: Radius.circular(base),
    bottomRight: Radius.circular(base),
  ),
);

TextStyle display({
  double size = 20,
  Color color = Palette.ink,
  FontWeight weight = FontWeight.w800,
  double? height,
}) => TextStyle(
  fontFamily: Fonts.display,
  fontSize: size,
  fontWeight: weight,
  color: color,
  height: height,
  letterSpacing: size >= 28 ? -1.0 : -0.3,
);

TextStyle mono({
  double size = 13,
  Color color = Palette.ink,
  FontWeight weight = FontWeight.w500,
}) => TextStyle(
  fontFamily: Fonts.mono,
  fontSize: size,
  fontWeight: weight,
  color: color,
);

ThemeData buildTheme() => ThemeData(
  useMaterial3: true,
  scaffoldBackgroundColor: Palette.porcelain,
  colorScheme: ColorScheme.fromSeed(
    seedColor: Palette.fir,
    primary: Palette.fir,
    secondary: Palette.chip,
    surface: Palette.card,
    error: Palette.fault,
  ),
  textTheme: ThemeData.light().textTheme.apply(
    bodyColor: Palette.ink,
    displayColor: Palette.ink,
  ),
  cardTheme: const CardThemeData(
    color: Palette.card,
    elevation: 0,
    margin: EdgeInsets.zero,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(Corners.card)),
      side: BorderSide(color: Palette.line),
    ),
  ),
  dividerTheme: const DividerThemeData(color: Palette.line, thickness: 1),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: Palette.card,
    labelStyle: const TextStyle(color: Palette.haze),
    prefixIconColor: Palette.haze,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(Corners.field),
      borderSide: const BorderSide(color: Palette.line),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(Corners.field),
      borderSide: const BorderSide(color: Palette.line),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(Corners.field),
      borderSide: const BorderSide(color: Palette.fir, width: 1.6),
    ),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      backgroundColor: Palette.board,
      foregroundColor: Colors.white,
      minimumSize: const Size.fromHeight(56),
      shape: const BeveledRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(Corners.bevel)),
      ),
      textStyle: const TextStyle(
        fontFamily: Fonts.display,
        fontSize: 16,
        fontWeight: FontWeight.w600,
      ),
    ),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      foregroundColor: Palette.ink,
      side: const BorderSide(color: Palette.ink, width: 1.2),
      minimumSize: const Size.fromHeight(54),
      shape: const BeveledRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(Corners.bevel)),
      ),
      textStyle: const TextStyle(
        fontFamily: Fonts.display,
        fontSize: 15,
        fontWeight: FontWeight.w600,
      ),
    ),
  ),
  textButtonTheme: TextButtonThemeData(
    style: TextButton.styleFrom(foregroundColor: Palette.fir),
  ),
  snackBarTheme: SnackBarThemeData(
    backgroundColor: Palette.board,
    contentTextStyle: const TextStyle(color: Colors.white, fontSize: 13.5),
    behavior: SnackBarBehavior.floating,
    shape: const BeveledRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(Corners.bevel)),
    ),
  ),
  navigationBarTheme: NavigationBarThemeData(
    backgroundColor: Palette.card,
    surfaceTintColor: Colors.transparent,
    indicatorColor: Palette.chipSoft,
    iconTheme: WidgetStateProperty.resolveWith(
      (states) => IconThemeData(
        color: states.contains(WidgetState.selected)
            ? Palette.ink
            : Palette.haze,
      ),
    ),
    labelTextStyle: WidgetStateProperty.resolveWith(
      (states) => TextStyle(
        fontFamily: Fonts.display,
        fontSize: 12,
        fontWeight: states.contains(WidgetState.selected)
            ? FontWeight.w700
            : FontWeight.w500,
        color: states.contains(WidgetState.selected)
            ? Palette.ink
            : Palette.haze,
      ),
    ),
  ),
  appBarTheme: const AppBarTheme(
    backgroundColor: Palette.porcelain,
    surfaceTintColor: Colors.transparent,
    elevation: 0,
  ),
);

/// The gold contact pads of a SIM chip, drawn as a mark.
class ChipContactMark extends StatelessWidget {
  const ChipContactMark({
    super.key,
    required this.size,
    this.chipColor = Palette.chip,
    this.etchColor = Palette.board,
  });
  final double size;
  final Color chipColor;
  final Color etchColor;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size(size, size * 0.78),
    painter: _ChipContactPainter(chipColor, etchColor),
  );
}

class _ChipContactPainter extends CustomPainter {
  const _ChipContactPainter(this.chipColor, this.etchColor);
  final Color chipColor;
  final Color etchColor;

  @override
  void paint(Canvas canvas, Size size) {
    final body = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(size.width * 0.18),
    );
    if (chipColor.a > 0) {
      canvas.drawRRect(body, Paint()..color = chipColor);
    }
    final etch = Paint()
      ..color = etchColor
      ..strokeWidth = size.width * 0.055
      ..style = PaintingStyle.stroke;
    canvas.drawRRect(body.deflate(etch.strokeWidth / 2), etch);
    final thirdX = size.width / 3;
    final midY = size.height / 2;
    canvas.drawLine(Offset(thirdX, 0), Offset(thirdX, size.height), etch);
    canvas.drawLine(
      Offset(thirdX * 2, 0),
      Offset(thirdX * 2, size.height),
      etch,
    );
    canvas.drawLine(Offset(0, midY), Offset(size.width, midY), etch);
  }

  @override
  bool shouldRepaint(covariant _ChipContactPainter old) =>
      old.chipColor != chipColor || old.etchColor != etchColor;
}

/// Brand mark: a gold SIM-chamfered tile carrying the contact chip.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, required this.size});
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: ShapeDecoration(
      color: Palette.chip,
      shape: simShape(cut: size * 0.46, base: size * 0.12),
    ),
    child: ChipContactMark(
      size: size * 0.48,
      chipColor: Colors.transparent,
      etchColor: Palette.board,
    ),
  );
}
