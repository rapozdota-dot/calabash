import 'package:calabash_maturity_detection/utils/constants.dart';
import 'package:calabash_maturity_detection/utils/ui_tokens.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Owns the existing palette and bundled Nunito Sans typography.
class AppTheme {
  AppTheme._();

  static ThemeData build() {
    GoogleFonts.config.allowRuntimeFetching = false;
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppConstants.primaryGreen,
        primary: AppConstants.primaryGreen,
        secondary: AppConstants.accentBrown,
        surface: Colors.white,
      ),
      scaffoldBackgroundColor: AppConstants.background,
    );
    final nunito = GoogleFonts.nunitoSansTextTheme(base.textTheme).apply(
      bodyColor: AppConstants.softText,
      displayColor: AppConstants.softText,
    );
    final text = nunito.copyWith(
      headlineMedium: nunito.headlineMedium?.copyWith(fontSize: 32),
      headlineSmall: nunito.headlineSmall?.copyWith(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        height: 1.25,
      ),
      titleLarge: nunito.titleLarge?.copyWith(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        height: 1.3,
      ),
      titleMedium: nunito.titleMedium?.copyWith(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        height: 1.4,
      ),
      // Retain the sizes used by the approved splash typography.
      titleSmall: nunito.titleSmall?.copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
      bodyLarge: nunito.bodyLarge?.copyWith(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        height: 1.5,
      ),
      bodyMedium: nunito.bodyMedium?.copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        height: 1.5,
      ),
      bodySmall: nunito.bodySmall?.copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        height: 1.4,
      ),
      labelLarge: nunito.labelLarge?.copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w500,
        height: 1.3,
      ),
    );
    return base.copyWith(
      textTheme: text,
      appBarTheme: AppBarTheme(
        centerTitle: true,
        elevation: 0,
        backgroundColor: AppConstants.background,
        foregroundColor: AppConstants.primaryGreen,
        titleTextStyle: text.titleLarge?.copyWith(
          color: AppConstants.primaryGreen,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: UiTokens.cardElevation,
        color: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppConstants.cardRadius),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        titleTextStyle: text.titleLarge,
        contentTextStyle: text.bodyLarge,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(UiTokens.dialogRadius),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppConstants.primaryGreen,
          textStyle: text.labelLarge,
          minimumSize: const Size(
            UiTokens.minimumTouchTarget,
            UiTokens.minimumTouchTarget,
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppConstants.primaryGreen,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(AppConstants.buttonHeight),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppConstants.cardRadius),
          ),
          textStyle: text.labelLarge,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(textStyle: text.labelLarge),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppConstants.primaryGreen,
          minimumSize: const Size.fromHeight(AppConstants.buttonHeight),
          side: const BorderSide(color: AppConstants.primaryGreen),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppConstants.cardRadius),
          ),
          textStyle: text.labelLarge,
        ),
      ),
    );
  }

  /// Chooses legible label text without changing the maturity indicator color.
  static Color onStatusColor(Color color) =>
      color.computeLuminance() > .179 ? Colors.black : Colors.white;
}
