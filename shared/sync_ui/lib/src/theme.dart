import 'package:flutter/material.dart';

import 'app_settings.dart';

/// Builds the [ThemeData] for a palette in one brightness.
///
/// Every palette provides both a light and a dark variant, because the palette
/// and the light/dark choice are separate settings: picking OLED and then Light
/// has to give something sensible rather than nothing.
ThemeData buildTheme(AppColorScheme scheme, Brightness brightness) {
  return switch (scheme) {
    AppColorScheme.synchronizer => _seeded(Colors.teal, brightness),
    AppColorScheme.oled =>
      brightness == Brightness.dark ? _oledDark() : _colourlessLight(),
    AppColorScheme.yaru => _yaru(brightness),
  };
}

/// The default: let Material derive the whole palette from one seed colour.
ThemeData _seeded(Color seed, Brightness brightness) {
  return ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: brightness),
    useMaterial3: true,
  );
}

/// Black where it counts, greyscale everywhere else: no hue at all, and true
/// black surfaces so OLED pixels are simply off.
ThemeData _oledDark() {
  const scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: Colors.white,
    onPrimary: Colors.black,
    secondary: Color(0xFFB0B0B0),
    onSecondary: Colors.black,
    error: Color(0xFFCF6679),
    onError: Colors.black,
    surface: Colors.black,
    onSurface: Colors.white,
    surfaceContainerLowest: Colors.black,
    surfaceContainerLow: Color(0xFF0A0A0A),
    surfaceContainer: Color(0xFF121212),
    surfaceContainerHigh: Color(0xFF181818),
    surfaceContainerHighest: Color(0xFF1F1F1F),
    onSurfaceVariant: Color(0xFFC4C4C4),
    outline: Color(0xFF5C5C5C),
    outlineVariant: Color(0xFF2C2C2C),
    inverseSurface: Colors.white,
    onInverseSurface: Colors.black,
  );

  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: Colors.black,
    canvasColor: Colors.black,
  );
}

/// The light half of the colourless palette, for when OLED is paired with a
/// light theme.
ThemeData _colourlessLight() {
  const scheme = ColorScheme(
    brightness: Brightness.light,
    primary: Color(0xFF1F1F1F),
    onPrimary: Colors.white,
    secondary: Color(0xFF5C5C5C),
    onSecondary: Colors.white,
    error: Color(0xFFB3261E),
    onError: Colors.white,
    surface: Colors.white,
    onSurface: Color(0xFF1A1A1A),
    surfaceContainerLowest: Colors.white,
    surfaceContainerLow: Color(0xFFFAFAFA),
    surfaceContainer: Color(0xFFF3F3F3),
    surfaceContainerHigh: Color(0xFFEDEDED),
    surfaceContainerHighest: Color(0xFFE7E7E7),
    onSurfaceVariant: Color(0xFF474747),
    outline: Color(0xFF8A8A8A),
    outlineVariant: Color(0xFFCFCFCF),
    inverseSurface: Color(0xFF1A1A1A),
    onInverseSurface: Colors.white,
  );

  return ThemeData(colorScheme: scheme, useMaterial3: true);
}

/// Ubuntu's greys. Deliberately mid-tone: the dark variant is a soft charcoal
/// rather than black, and the light variant a warm grey rather than white, so
/// it reads as the middle ground between the two.
ThemeData _yaru(Brightness brightness) {
  const orange = Color(0xFFE95420); // Ubuntu's accent, used sparingly
  final dark = brightness == Brightness.dark;

  final scheme = dark
      ? const ColorScheme(
          brightness: Brightness.dark,
          primary: orange,
          onPrimary: Colors.white,
          secondary: Color(0xFF787878),
          onSecondary: Colors.white,
          error: Color(0xFFE86A6A),
          onError: Colors.white,
          surface: Color(0xFF3B3B3B),
          onSurface: Color(0xFFF2F2F2),
          surfaceContainerLowest: Color(0xFF303030),
          surfaceContainerLow: Color(0xFF363636),
          surfaceContainer: Color(0xFF3B3B3B),
          surfaceContainerHigh: Color(0xFF444444),
          surfaceContainerHighest: Color(0xFF4D4D4D),
          onSurfaceVariant: Color(0xFFD0D0D0),
          outline: Color(0xFF8C8C8C),
          outlineVariant: Color(0xFF5A5A5A),
          inverseSurface: Color(0xFFF2F2F2),
          onInverseSurface: Color(0xFF303030),
        )
      : const ColorScheme(
          brightness: Brightness.light,
          primary: orange,
          onPrimary: Colors.white,
          secondary: Color(0xFF6A6A6A),
          onSecondary: Colors.white,
          error: Color(0xFFB3261E),
          onError: Colors.white,
          surface: Color(0xFFEDEBE9),
          onSurface: Color(0xFF2C2C2C),
          surfaceContainerLowest: Color(0xFFF7F5F3),
          surfaceContainerLow: Color(0xFFF2F0EE),
          surfaceContainer: Color(0xFFEDEBE9),
          surfaceContainerHigh: Color(0xFFE4E1DE),
          surfaceContainerHighest: Color(0xFFDAD7D3),
          onSurfaceVariant: Color(0xFF4A4A4A),
          outline: Color(0xFF8C8C8C),
          outlineVariant: Color(0xFFC4C0BC),
          inverseSurface: Color(0xFF2C2C2C),
          onInverseSurface: Color(0xFFF2F0EE),
        );

  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: scheme.surface,
  );
}
