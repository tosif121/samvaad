import 'package:flutter/material.dart';

/// Central spacing scale — no magic numbers in UI code.
abstract final class AppSpacing {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 24;
  static const double xxl = 32;
}

/// Central radius scale.
abstract final class AppRadii {
  static const double sm = 10;
  static const double md = 14;
  static const double lg = 18;
  static const double xl = 24;
  static const double pill = 999;
}

/// Central sizing scale for avatars / buttons.
abstract final class AppSizes {
  static const double avatarXl = 120;
  static const double avatarLg = 72;
  static const double avatarMd = 48;
  static const double avatarSm = 40;
  static const double callAction = 68;
  static const double callControl = 54;
  static const double endButton = 76;
}

/// Central type scale.
abstract final class AppType {
  static const double display = 32;
  static const double title = 26;
  static const double heading = 19;
  static const double subheading = 16;
  static const double body = 14;
  static const double caption = 12;
  static const double overline = 11;
}

/// Central motion durations & curves.
abstract final class AppMotion {
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration normal = Duration(milliseconds: 260);
  static const Duration slow = Duration(milliseconds: 420);
  static const Curve easeOut = Curves.easeOutCubic;
  static const Curve easeInOut = Curves.easeInOutCubic;
}
