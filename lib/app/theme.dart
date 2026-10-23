import 'package:flutter/material.dart';

abstract class AppColors {
  static const Color primaryBlack = Color(0xFF000000);
  static const Color backgroundWhite = Color(0xFFFFFFFF);
  static const Color lightGray = Color(0xFFF5F5F5);
  static const Color borderGray = Color(0xFFE0E0E0);
  static const Color darkGray = Color(0xFF424242);
  static const Color mediumGray = Color(0xFF757575);
}

abstract class AppSpacing {
  static const double s4 = 4.0;
  static const double s8 = 8.0;
  static const double s12 = 12.0;
  static const double s16 = 16.0;
  static const double s20 = 20.0;
  static const double s24 = 24.0;
  static const double s32 = 32.0;
}

abstract class AppShapes {
  static const double inputRadius = 12.0;
  static const double buttonRadius = 12.0;
  static const double cardRadius = 16.0;

  static final BorderRadius inputBorderRadius = BorderRadius.circular(inputRadius);
  static final BorderRadius buttonBorderRadius = BorderRadius.circular(buttonRadius);
  static final BorderRadius cardBorderRadius = BorderRadius.circular(cardRadius);

  static final RoundedRectangleBorder inputShape = RoundedRectangleBorder(
    borderRadius: inputBorderRadius,
    side: const BorderSide(color: AppColors.borderGray, width: 1.0),
  );

  static final RoundedRectangleBorder buttonShape = RoundedRectangleBorder(
    borderRadius: buttonBorderRadius,
  );

  static final RoundedRectangleBorder cardShape = RoundedRectangleBorder(
    borderRadius: cardBorderRadius,
    side: const BorderSide(color: AppColors.borderGray, width: 1.0),
  );
}

abstract class AppTheme {
  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: AppColors.backgroundWhite,
      colorScheme: const ColorScheme.light(
        primary: AppColors.primaryBlack,
        onPrimary: AppColors.backgroundWhite,
        secondary: AppColors.darkGray,
        onSecondary: AppColors.backgroundWhite,
        surface: AppColors.backgroundWhite,
        onSurface: AppColors.primaryBlack,
        surfaceContainerHighest: AppColors.lightGray,
        onSurfaceVariant: AppColors.darkGray,
        outline: AppColors.borderGray,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.backgroundWhite,
        foregroundColor: AppColors.primaryBlack,
        elevation: 0,
        centerTitle: false,
        iconTheme: IconThemeData(color: AppColors.primaryBlack),
        titleTextStyle: TextStyle(
          color: AppColors.primaryBlack,
          fontSize: 20,
          fontWeight: FontWeight.bold,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primaryBlack,
          foregroundColor: AppColors.backgroundWhite,
          elevation: 0,
          shape: AppShapes.buttonShape,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.s20,
            vertical: AppSpacing.s12,
          ),
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.primaryBlack,
          backgroundColor: AppColors.backgroundWhite,
          side: const BorderSide(color: AppColors.borderGray, width: 1.0),
          shape: AppShapes.buttonShape,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.s20,
            vertical: AppSpacing.s12,
          ),
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.primaryBlack,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.s16,
            vertical: AppSpacing.s8,
          ),
        ),
      ),
      cardTheme: CardTheme(
        color: AppColors.backgroundWhite,
        elevation: 0,
        shape: AppShapes.cardShape,
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.lightGray,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s16,
          vertical: AppSpacing.s12,
        ),
        border: OutlineInputBorder(
          borderRadius: AppShapes.inputBorderRadius,
          borderSide: const BorderSide(color: AppColors.borderGray, width: 1.0),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: AppShapes.inputBorderRadius,
          borderSide: const BorderSide(color: AppColors.borderGray, width: 1.0),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: AppShapes.inputBorderRadius,
          borderSide: const BorderSide(color: AppColors.primaryBlack, width: 1.5),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.borderGray,
        thickness: 1.0,
        space: 1.0,
      ),
      iconTheme: const IconThemeData(
        color: AppColors.primaryBlack,
      ),
    );
  }
}
