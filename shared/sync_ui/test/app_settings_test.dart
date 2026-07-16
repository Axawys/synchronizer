import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sync_ui/sync_ui.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('AppSettings', () {
    test('defaults to the original look following the system theme', () async {
      final settings = AppSettings();
      await settings.load();

      expect(settings.scheme, AppColorScheme.synchronizer);
      expect(settings.themeMode, ThemeMode.system);
    });

    test('remembers the chosen scheme and theme', () async {
      await AppSettings().setScheme(AppColorScheme.oled);
      await AppSettings().setThemeMode(ThemeMode.dark);

      final reloaded = AppSettings();
      await reloaded.load();

      expect(reloaded.scheme, AppColorScheme.oled);
      expect(reloaded.themeMode, ThemeMode.dark);
    });

    test('notifies listeners so the app can restyle itself', () async {
      final settings = AppSettings();
      var notified = 0;
      settings.addListener(() => notified++);

      await settings.setScheme(AppColorScheme.yaru);
      await settings.setThemeMode(ThemeMode.light);

      expect(notified, 2);
    });

    test('setting the same value again does not notify', () async {
      final settings = AppSettings();
      var notified = 0;
      settings.addListener(() => notified++);

      await settings.setScheme(AppColorScheme.synchronizer); // already the default

      expect(notified, 0);
    });

    test('falls back to defaults if a stored value is unrecognised', () async {
      SharedPreferences.setMockInitialValues({
        'color_scheme': 'no-such-scheme',
        'theme_mode': 'sideways',
      });

      final settings = AppSettings();
      await settings.load();

      expect(settings.scheme, AppColorScheme.synchronizer);
      expect(settings.themeMode, ThemeMode.system);
    });
  });

  group('buildTheme', () {
    test('every scheme provides both a light and a dark variant', () {
      for (final scheme in AppColorScheme.values) {
        expect(buildTheme(scheme, Brightness.light).colorScheme.brightness,
            Brightness.light,
            reason: scheme.name);
        expect(buildTheme(scheme, Brightness.dark).colorScheme.brightness,
            Brightness.dark,
            reason: scheme.name);
      }
    });

    test('OLED dark is true black, so the pixels can switch off', () {
      final theme = buildTheme(AppColorScheme.oled, Brightness.dark);
      expect(theme.colorScheme.surface, Colors.black);
      expect(theme.scaffoldBackgroundColor, Colors.black);
    });

    test('OLED carries no hue', () {
      final scheme = buildTheme(AppColorScheme.oled, Brightness.dark).colorScheme;
      for (final colour in [scheme.primary, scheme.surface, scheme.onSurface]) {
        expect(HSLColor.fromColor(colour).saturation, 0,
            reason: 'expected a greyscale colour');
      }
    });

    test('Yaru dark sits above black, as a middle ground', () {
      final theme = buildTheme(AppColorScheme.yaru, Brightness.dark);
      final surface = theme.colorScheme.surface;
      expect(surface, isNot(Colors.black));
      // Comfortably grey rather than near-black.
      expect(HSLColor.fromColor(surface).lightness, greaterThan(0.15));
    });
  });
}
