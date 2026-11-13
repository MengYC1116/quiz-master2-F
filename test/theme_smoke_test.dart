// R1 Token 冒烟测试：token / theme 层对照 HTML 视觉基准。
//
// 只验证 token / theme 层（值与 HTML :root / 深色 @media 对照、
// 三档缩放、深浅主题构造）；不写业务断言。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/theme/app_theme.dart'; // 同时 re-export design_tokens.dart

void main() {
  test('AppTheme light/dark ThemeData 可构造', () {
    expect(() => AppTheme.light(), returnsNormally);
    expect(() => AppTheme.dark(), returnsNormally);
    expect(() => AppTheme.light(scale: 1.15), returnsNormally);
    expect(() => AppTheme.dark(scale: 1.3), returnsNormally);
  });

  test('浅色底色与深色底色常量存在且不同', () {
    expect(AppTheme.lightBackground, isNot(AppTheme.darkBackground));
    expect(AppTheme.accent, isNot(AppTheme.darkAccent));
  });

  test('浅色 token 与 HTML :root 对照', () {
    final p = DesignTokens.light;
    expect(p.background, const Color(0xFFFDF8EC));
    expect(p.surface, const Color(0xFFFFFEF9));
    expect(p.surface2, const Color(0xFFFDF3D8));
    expect(p.surface3, const Color(0xFFF3E9C8));
    expect(p.ink, const Color(0xFF17233B));
    expect(p.ink2, const Color(0xFF3D4E6B));
    expect(p.muted, const Color(0xFF5F718E));
    expect(p.line, const Color(0xFFE8DFC2));
    expect(p.lineStrong, const Color(0xFFCFC39E));
    expect(p.accent, const Color(0xFF2E7CF6));
    expect(p.accentSoft, const Color(0xFFE1EDFF));
    expect(p.accentInk, const Color(0xFFFFFFFF));
    expect(p.accentText, const Color(0xFF175CD3));
    expect(p.paper, const Color(0xFFFFFDF4));
    expect(p.paperInk, const Color(0xFF22251F));
    expect(p.paperLine, const Color(0xFFE3D9BE));
    expect(p.stem, const Color(0xFF2E7CF6));
    expect(p.option, const Color(0xFF00A884));
    expect(p.figure, const Color(0xFFF97316));
    expect(p.math, const Color(0xFF2E7CF6));
    expect(p.eng, const Color(0xFF00A884));
    expect(p.pol, const Color(0xFFEF4444));
    expect(p.warnBg, const Color(0xFFFFF3D1));
    expect(p.warnInk, const Color(0xFF8A5A00));
    expect(p.errBg, const Color(0xFFFFE9E5));
    expect(p.errInk, const Color(0xFFB42318));
    expect(p.keep, const Color(0xFF0E9F6E));
    expect(p.merge, const Color(0xFFB97A0A));
    expect(p.cut, const Color(0xFFD93A2B));
  });

  test('深色 token 与 HTML 深色 @media 对照', () {
    final p = DesignTokens.dark;
    expect(p.background, const Color(0xFF1E2228));
    expect(p.surface, const Color(0xFF262B33));
    expect(p.surface2, const Color(0xFF21262E));
    expect(p.surface3, const Color(0xFF333A45));
    expect(p.ink, const Color(0xFFE9EDF3));
    expect(p.ink2, const Color(0xFFC6CEDA));
    expect(p.muted, const Color(0xFF97A2B2));
    expect(p.line, const Color(0xFF333B47));
    expect(p.lineStrong, const Color(0xFF485364));
    expect(p.accent, const Color(0xFF7FA8D0));
    expect(p.accentSoft, const Color(0xFF2C3949));
    expect(p.accentInk, const Color(0xFF131A24));
    expect(p.accentText, const Color(0xFFA9C6E4));
    // 深色纸面 #D8DCE2：深色下打开的书仍是浅灰纸页（负责人已确认）。
    expect(p.paper, const Color(0xFFD8DCE2));
    expect(p.paperInk, const Color(0xFF232830));
    expect(p.paperLine, const Color(0xFFAEB6C2));
    expect(p.stem, const Color(0xFF7FA8D0));
    expect(p.option, const Color(0xFF8FB8A4));
    expect(p.figure, const Color(0xFFA79BC0));
    expect(p.math, const Color(0xFF87A9CC));
    expect(p.eng, const Color(0xFF8AB5A3));
    expect(p.pol, const Color(0xFFC295A5));
    expect(p.mathInk, const Color(0xFFACC8E2));
    expect(p.engInk, const Color(0xFFAFD2C2));
    expect(p.polInk, const Color(0xFFD8B4C0));
  });

  test('深色主按钮用深色字、导航选中统一用 #7FA8D0', () {
    final dark = AppTheme.dark();
    expect(dark.colorScheme.primary, const Color(0xFF7FA8D0));
    expect(dark.colorScheme.onPrimary, const Color(0xFF131A24));
    expect(AppTheme.darkNavSelected, const Color(0xFF7FA8D0));
    expect(AppTheme.darkNavSelectedInk, const Color(0xFF131A24));
    final light = AppTheme.light();
    expect(light.colorScheme.primary, const Color(0xFF2E7CF6));
    expect(light.colorScheme.onPrimary, const Color(0xFFFFFFFF));
  });

  test('字号缩放 1.00 / 1.15 / 1.30 三档（D4）', () {
    expect(FontScale.factorFor('standard'), 1.0);
    expect(FontScale.factorFor('large'), 1.15);
    expect(FontScale.factorFor('extraLarge'), 1.3);
    expect(const AppSettings(fontSize: 'standard').fontScale, 1.0);
    expect(const AppSettings(fontSize: 'large').fontScale, 1.15);
    expect(const AppSettings(fontSize: 'extraLarge').fontScale, 1.3);
    // 旧值 1.12 / 1.25 不得再出现。
    expect(FontScale.factorFor('large'), isNot(1.12));
    expect(FontScale.factorFor('extraLarge'), isNot(1.25));
    // token 布局尺寸按同一因子缩放，且只缩放一次。
    expect(DesignTokens.scaled(1.15).radius, closeTo(13.8, 0.001));
    expect(DesignTokens.scaled(1.3).radiusLg, closeTo(20.8, 0.001));
  });

  test('学科色与封面色分离（D6）：封面蓝 ≠ 学科蓝', () {
    expect(CoverTokens.of('blue'), const Color(0xFF2F7CF6));
    expect(DesignTokens.light.math, const Color(0xFF2E7CF6));
    expect(CoverTokens.of('blue'), isNot(DesignTokens.light.math));
    expect(CoverTokens.of('purple'), const Color(0xFF7C4DDB));
    expect(CoverTokens.of('orange'), const Color(0xFFED7D31));
    expect(CoverTokens.of('yellow'), const Color(0xFFD9A404));
    expect(CoverTokens.of('grey'), const Color(0xFF64748F));
    expect(CoverTokens.styles.length, 6);
    // models 层的学科色 / 封面色与 token 层一致。
    expect(Subject.math.color, DesignTokens.light.math);
    expect(Subject.english.color, DesignTokens.light.eng);
    expect(Subject.politics.color, DesignTokens.light.pol);
    expect(CoverColors.of('blue'), CoverTokens.of('blue'));
  });

  test('字体与字号 token', () {
    expect(DesignTokens.fontFamily, 'Segoe UI');
    expect(DesignTokens.bodyFontSize, 15);
    expect(DesignTokens.bodyLineHeight, 1.65);
    expect(DesignTokens.pageTitleFontSize, 24);
    expect(DesignTokens.focusNumberFontSize, 46);
    expect(DesignTokens.radius, 12);
    expect(DesignTokens.radiusLg, 16);
    final light = AppTheme.light();
    expect(light.textTheme.bodyMedium?.fontSize, 15);
    expect(light.textTheme.bodyMedium?.fontFamily, 'Segoe UI');
  });
}
