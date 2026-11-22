part of 'wrongbook_page.dart';

// 页内共用叶部件：纸面小按钮与紧凑行收藏星。

/// 目录页行内操作按钮（HTML `.tbtn` 的 Flutter 实现：
/// 纸面上的小按钮，1px #B9C6D8 边、白底 65%、#3D4E6B 字、
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
