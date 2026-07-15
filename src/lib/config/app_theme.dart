import 'package:flutter/material.dart';
import '../services/app_preferences_service.dart';

/// Ocean Blue (Classic) and Cyberpunk/Minimalist (Modern) themes for Mobile AI Agent
class AppTheme {
  AppTheme._();

  // === Primary Colors (Ocean Blue #0277BD) ===
  static const Color primaryBlue = Color(0xFF0277BD);
  static const Color primaryLight = Color(0xFF58A5F0);
  static const Color primaryDark = Color(0xFF004C8C);

  // === Server Mode Colors (Teal #00838F) ===
  static const Color serverBlue = Color(0xFF00838F);
  static const Color serverBlueDark = Color(0xFF005662);

  // === Surface / Background ===
  static const Color backgroundDark = Color(0xFF0A1628);
  static const Color backgroundLight = Color(0xFFF0F4FA);
  static const Color surfaceDark = Color(0xFF112240);
  static const Color surfaceLight = Color(0xFFFFFFFF);
  static const Color cardDark = Color(0xFF1A2F50);
  static const Color cardLight = Color(0xFFE8F0FE);

  // === Accent ===
  static const Color accent = Color(0xFF00BCD4); // Cyan accent
  static const Color accentLight = Color(0xFF62EFFF);

  // === Text ===
  static const Color textOnDark = Color(0xFFE1E8F0);
  static const Color textOnLight = Color(0xFF1A2030);
  static const Color textSecondaryDark = Color(0xFF8899B0);
  static const Color textSecondaryLight = Color(0xFF5A6880);

  // === Status ===
  static const Color success = Color(0xFF4CAF50);
  static const Color warning = Color(0xFFFFA726);
  static const Color error = Color(0xFFEF5350);

  // === Chat Bubbles ===
  static const Color userBubbleDark = Color(0xFF0277BD);
  static const Color userBubbleLight = Color(0xFF0288D1);
  static const Color assistantBubbleDark = Color(0xFF1A2F50);
  static const Color assistantBubbleLight = Color(0xFFE3F2FD);

  // ──────────────────────────────────────────────
  // Dynamic Selectors
  // ──────────────────────────────────────────────
  static ThemeData get darkTheme =>
      AppPreferencesService.instance.uiStyle == 'classic'
          ? _classicDarkTheme
          : _modernDarkTheme;

  static ThemeData get lightTheme =>
      AppPreferencesService.instance.uiStyle == 'classic'
          ? _classicLightTheme
          : _modernLightTheme;

  static ThemeData get serverDarkTheme =>
      AppPreferencesService.instance.uiStyle == 'classic'
          ? _classicServerDarkTheme
          : _modernServerDarkTheme;

  static ThemeData get serverLightTheme =>
      AppPreferencesService.instance.uiStyle == 'classic'
          ? _classicServerLightTheme
          : _modernServerLightTheme;

  // ──────────────────────────────────────────────
  // Classic Dark Theme
  // ──────────────────────────────────────────────
  static ThemeData get _classicDarkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: primaryBlue,
        brightness: Brightness.dark,
        surface: surfaceDark,
        primary: primaryBlue,
        secondary: accent,
        error: error,
      ),
      scaffoldBackgroundColor: backgroundDark,
      appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF0D1B33), foregroundColor: textOnDark, elevation: 0, centerTitle: false),
      cardTheme: CardThemeData(
        color: cardDark,
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(backgroundColor: primaryBlue, foregroundColor: Colors.white),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF152238),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF2A3F5F)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF2A3F5F)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: primaryBlue, width: 2),
        ),
        hintStyle: const TextStyle(color: textSecondaryDark),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryBlue,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        ),
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(color: textOnDark, fontWeight: FontWeight.bold),
        headlineMedium: TextStyle(color: textOnDark, fontWeight: FontWeight.w600),
        bodyLarge: TextStyle(color: textOnDark),
        bodyMedium: TextStyle(color: textSecondaryDark),
      ),
      dividerColor: const Color(0xFF2A3F5F),
      tabBarTheme: const TabBarThemeData(labelColor: Colors.white, unselectedLabelColor: Color(0xAAFFFFFF), indicatorColor: Colors.white),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: const Color(0xFF0D1B33),
        indicatorColor: primaryBlue.withValues(alpha: 0.3),
      ),
    );
  }

  // ──────────────────────────────────────────────
  // Classic Light Theme
  // ──────────────────────────────────────────────
  static ThemeData get _classicLightTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: primaryBlue,
        brightness: Brightness.light,
        surface: surfaceLight,
        primary: primaryBlue,
        secondary: accent,
        error: error,
      ),
      scaffoldBackgroundColor: backgroundLight,
      appBarTheme: const AppBarTheme(backgroundColor: primaryBlue, foregroundColor: Colors.white, elevation: 0, centerTitle: false),
      cardTheme: CardThemeData(
        color: cardLight,
        elevation: 1,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(backgroundColor: primaryBlue, foregroundColor: Colors.white),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFB0C4DE)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFB0C4DE)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: primaryBlue, width: 2),
        ),
        hintStyle: const TextStyle(color: textSecondaryLight),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryBlue,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        ),
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(color: textOnLight, fontWeight: FontWeight.bold),
        headlineMedium: TextStyle(color: textOnLight, fontWeight: FontWeight.w600),
        bodyLarge: TextStyle(color: textOnLight),
        bodyMedium: TextStyle(color: textSecondaryLight),
      ),
      dividerColor: const Color(0xFFD0D8E8),
      tabBarTheme: const TabBarThemeData(labelColor: Colors.white, unselectedLabelColor: Color(0xCCFFFFFF), indicatorColor: Colors.white),
      navigationBarTheme: NavigationBarThemeData(backgroundColor: Colors.white, indicatorColor: primaryBlue.withValues(alpha: 0.15)),
    );
  }

  // ──────────────────────────────────────────────
  // Classic Server Dark Theme
  // ──────────────────────────────────────────────
  static ThemeData get _classicServerDarkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: serverBlue,
        brightness: Brightness.dark,
        surface: surfaceDark,
        primary: serverBlue,
        secondary: accent,
        error: error,
      ),
      scaffoldBackgroundColor: backgroundDark,
      appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF0A1E21), foregroundColor: textOnDark, elevation: 0, centerTitle: false),
      cardTheme: CardThemeData(
        color: cardDark,
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(backgroundColor: serverBlue, foregroundColor: Colors.white),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF152238),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF1E3A3E)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF1E3A3E)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: serverBlue, width: 2),
        ),
        hintStyle: const TextStyle(color: textSecondaryDark),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: serverBlue,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        ),
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(color: textOnDark, fontWeight: FontWeight.bold),
        headlineMedium: TextStyle(color: textOnDark, fontWeight: FontWeight.w600),
        bodyLarge: TextStyle(color: textOnDark),
        bodyMedium: TextStyle(color: textSecondaryDark),
      ),
      dividerColor: const Color(0xFF1E3A3E),
      tabBarTheme: const TabBarThemeData(labelColor: Colors.white, unselectedLabelColor: Color(0xAAFFFFFF), indicatorColor: Colors.white),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: const Color(0xFF0A1E21),
        indicatorColor: serverBlue.withValues(alpha: 0.3),
      ),
    );
  }

  // ──────────────────────────────────────────────
  // Classic Server Light Theme
  // ──────────────────────────────────────────────
  static ThemeData get _classicServerLightTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: serverBlue,
        brightness: Brightness.light,
        surface: surfaceLight,
        primary: serverBlue,
        secondary: accent,
        error: error,
      ),
      scaffoldBackgroundColor: backgroundLight,
      appBarTheme: const AppBarTheme(backgroundColor: serverBlue, foregroundColor: Colors.white, elevation: 0, centerTitle: false),
      cardTheme: CardThemeData(
        color: cardLight,
        elevation: 1,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(backgroundColor: serverBlue, foregroundColor: Colors.white),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFB0C4C4)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFB0C4C4)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: serverBlue, width: 2),
        ),
        hintStyle: const TextStyle(color: textSecondaryLight),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: serverBlue,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        ),
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(color: textOnLight, fontWeight: FontWeight.bold),
        headlineMedium: TextStyle(color: textOnLight, fontWeight: FontWeight.w600),
        bodyLarge: TextStyle(color: textOnLight),
        bodyMedium: TextStyle(color: textSecondaryLight),
      ),
      dividerColor: const Color(0xFFCCD8D8),
      tabBarTheme: const TabBarThemeData(labelColor: Colors.white, unselectedLabelColor: Color(0xCCFFFFFF), indicatorColor: Colors.white),
      navigationBarTheme: NavigationBarThemeData(backgroundColor: Colors.white, indicatorColor: serverBlue.withValues(alpha: 0.15)),
    );
  }

  // ──────────────────────────────────────────────
  // Modern Dark Theme (Cyberpunk Obsidian / Neon)
  // ──────────────────────────────────────────────
  static ThemeData get _modernDarkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF7C3AED), // Violet primary
        brightness: Brightness.dark,
        surface: const Color(0xFF121624),
        primary: const Color(0xFF7C3AED),
        secondary: const Color(0xFF06B6D4), // Cyan accent
        error: error,
      ),
      scaffoldBackgroundColor: const Color(0xFF0A0D14),
      appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF0A0D14), foregroundColor: Colors.white, elevation: 0, centerTitle: false),
      cardTheme: CardThemeData(
        color: const Color(0xFF161C2E).withValues(alpha: 0.65),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFF222B45), width: 1),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(backgroundColor: Color(0xFF7C3AED), foregroundColor: Colors.white),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF161C2E),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF222B45)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF222B45)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF7C3AED), width: 2),
        ),
        hintStyle: const TextStyle(color: Colors.grey),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF7C3AED),
          foregroundColor: Colors.white,
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFF7C3AED),
          side: const BorderSide(color: Color(0xFF7C3AED)),
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF7C3AED),
          foregroundColor: Colors.white,
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        ),
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        headlineMedium: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        bodyLarge: TextStyle(color: Colors.white),
        bodyMedium: TextStyle(color: Colors.grey),
      ),
      dividerColor: const Color(0xFF222B45),
      tabBarTheme: const TabBarThemeData(labelColor: Colors.white, unselectedLabelColor: Color(0xAAFFFFFF), indicatorColor: Colors.white),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: const Color(0xFF0A0D14),
        indicatorColor: const Color(0xFF7C3AED).withValues(alpha: 0.3),
      ),
    );
  }

  // ──────────────────────────────────────────────
  // Modern Light Theme (Warm Minimalist Pastel)
  // ──────────────────────────────────────────────
  static ThemeData get _modernLightTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF7C3AED), // Lilac
        brightness: Brightness.light,
        surface: const Color(0xFFFFFFFF),
        primary: const Color(0xFF7C3AED),
        secondary: const Color(0xFF34D399), // Mint
        error: error,
      ),
      scaffoldBackgroundColor: const Color(0xFFF8F9FC),
      appBarTheme: const AppBarTheme(backgroundColor: Color(0xFFF8F9FC), foregroundColor: Color(0xFF1F2937), elevation: 0, centerTitle: false),
      cardTheme: CardThemeData(
        color: Colors.white.withValues(alpha: 0.65),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFFE5E7EB), width: 1),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(backgroundColor: Color(0xFF7C3AED), foregroundColor: Colors.white),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFFFFFFFF),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF7C3AED), width: 2),
        ),
        hintStyle: const TextStyle(color: Colors.grey),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF7C3AED),
          foregroundColor: Colors.white,
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFF7C3AED),
          side: const BorderSide(color: Color(0xFF7C3AED)),
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF7C3AED),
          foregroundColor: Colors.white,
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        ),
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(color: Color(0xFF1F2937), fontWeight: FontWeight.bold),
        headlineMedium: TextStyle(color: Color(0xFF1F2937), fontWeight: FontWeight.w600),
        bodyLarge: TextStyle(color: Color(0xFF1F2937)),
        bodyMedium: TextStyle(color: Color(0xFF6B7280)),
      ),
      dividerColor: const Color(0xFFE5E7EB),
      tabBarTheme: const TabBarThemeData(labelColor: Color(0xFF1F2937), unselectedLabelColor: Color(0xAA1F2937), indicatorColor: Color(0xFF7C3AED)),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: const Color(0xFFFFFFFF),
        indicatorColor: const Color(0xFF7C3AED).withValues(alpha: 0.15),
      ),
    );
  }

  // ──────────────────────────────────────────────
  // Modern Server Dark Theme
  // ──────────────────────────────────────────────
  static ThemeData get _modernServerDarkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: serverBlue,
        brightness: Brightness.dark,
        surface: const Color(0xFF121624),
        primary: serverBlue,
        secondary: const Color(0xFF06B6D4),
        error: error,
      ),
      scaffoldBackgroundColor: const Color(0xFF0A0D14),
      appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF0A0D14), foregroundColor: Colors.white, elevation: 0, centerTitle: false),
      cardTheme: CardThemeData(
        color: const Color(0xFF161C2E).withValues(alpha: 0.65),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFF1E3A3E), width: 1),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(backgroundColor: serverBlue, foregroundColor: Colors.white),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF161C2E),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF1E3A3E)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF1E3A3E)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: serverBlue, width: 2),
        ),
        hintStyle: const TextStyle(color: Colors.grey),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: serverBlue,
          foregroundColor: Colors.white,
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: serverBlue,
          side: const BorderSide(color: serverBlue),
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: serverBlue,
          foregroundColor: Colors.white,
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        ),
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        headlineMedium: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        bodyLarge: TextStyle(color: Colors.white),
        bodyMedium: TextStyle(color: Colors.grey),
      ),
      dividerColor: const Color(0xFF1E3A3E),
      tabBarTheme: const TabBarThemeData(labelColor: Colors.white, unselectedLabelColor: Color(0xAAFFFFFF), indicatorColor: Colors.white),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: const Color(0xFF0A0D14),
        indicatorColor: serverBlue.withValues(alpha: 0.3),
      ),
    );
  }

  // ──────────────────────────────────────────────
  // Modern Server Light Theme
  // ──────────────────────────────────────────────
  static ThemeData get _modernServerLightTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: serverBlue,
        brightness: Brightness.light,
        surface: const Color(0xFFFFFFFF),
        primary: serverBlue,
        secondary: const Color(0xFF34D399),
        error: error,
      ),
      scaffoldBackgroundColor: const Color(0xFFF8F9FC),
      appBarTheme: const AppBarTheme(backgroundColor: Color(0xFFF8F9FC), foregroundColor: Color(0xFF1F2937), elevation: 0, centerTitle: false),
      cardTheme: CardThemeData(
        color: Colors.white.withValues(alpha: 0.65),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFFB0C4C4), width: 1),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(backgroundColor: serverBlue, foregroundColor: Colors.white),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFFFFFFFF),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFB0C4C4)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFB0C4C4)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: serverBlue, width: 2),
        ),
        hintStyle: const TextStyle(color: Colors.grey),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: serverBlue,
          foregroundColor: Colors.white,
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: serverBlue,
          side: const BorderSide(color: serverBlue),
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: serverBlue,
          foregroundColor: Colors.white,
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        ),
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(color: Color(0xFF1F2937), fontWeight: FontWeight.bold),
        headlineMedium: TextStyle(color: Color(0xFF1F2937), fontWeight: FontWeight.w600),
        bodyLarge: TextStyle(color: Color(0xFF1F2937)),
        bodyMedium: TextStyle(color: Color(0xFF6B7280)),
      ),
      dividerColor: const Color(0xFFCCD8D8),
      tabBarTheme: const TabBarThemeData(labelColor: Color(0xFF1F2937), unselectedLabelColor: Color(0xAA1F2937), indicatorColor: serverBlue),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: const Color(0xFFFFFFFF),
        indicatorColor: serverBlue.withValues(alpha: 0.15),
      ),
    );
  }
}
