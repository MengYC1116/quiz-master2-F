part of 'wrongbook_page.dart';

// 页内共用叶部件：纸面小按钮与紧凑行收藏星。

/// 目录页行内操作按钮（HTML `.tbtn` 的 Flutter 实现：
/// 纸面上的小按钮，1px #B9AE8E 边、白底 65%、#3D4438 字、
/// 13px/700、圆角 10、最小高 34px；危险态为红字红边）。
class _QmPaperButton extends StatelessWidget {
  const _QmPaperButton({
    required this.label,
    required this.onPressed,
    required this.danger,
    required this.scale,
    required this.palette,
  });
  final String label;
  final VoidCallback onPressed;
  final bool danger;
  final double scale;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final border = danger ? palette.errLine : palette.paperBtnBorder;
    final fg = danger ? palette.errInk : palette.paperBtnText;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(10 * scale),
        child: Container(
          constraints: BoxConstraints(minHeight: 34 * scale),
          padding: EdgeInsets.symmetric(
            horizontal: 12 * scale,
            vertical: 5 * scale,
          ),
          decoration: BoxDecoration(
            color: const Color.fromRGBO(255, 255, 255, 0.65),
            border: Border.all(color: border),
            borderRadius: BorderRadius.circular(10 * scale),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: fg,
              height: DesignTokens.controlLineHeight,
            ),
          ),
        ),
      ),
    );
  }
}

/// 紧凑行里的收藏星（HTML `.nb-prow .nb-star`：
/// 未收藏 #B9C2CE、已收藏 #E8A13A，19px）。
class _PaperStarButton extends StatelessWidget {
  const _PaperStarButton({required this.favorite, required this.onPressed});
  final bool favorite;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    return GestureDetector(
      onTap: onPressed,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Text(
          favorite ? '★' : '☆',
          style: TextStyle(
            fontSize: DesignTokens.prowStarFontSize,
            color: favorite ? palette.paperStarOn : palette.paperStar,
            height: 1,
          ),
        ),
      ),
    );
  }
}
