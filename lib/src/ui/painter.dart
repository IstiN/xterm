import 'dart:ui';
import 'package:flutter/painting.dart';

import 'package:xterm/src/ui/palette_builder.dart';
import 'package:xterm/src/ui/paragraph_cache.dart';
import 'package:xterm/xterm.dart';

/// Encapsulates the logic for painting various terminal elements.
class TerminalPainter {
  TerminalPainter({
    required TerminalTheme theme,
    required TerminalStyle textStyle,
    required TextScaler textScaler,
  })  : _textStyle = textStyle,
        _theme = theme,
        _textScaler = textScaler;

  /// Reusable CellData to avoid allocation per line during paint.
  final _reusableCellData = CellData.empty();

  /// A lookup table from terminal colors to Flutter colors.
  late var _colorPalette = PaletteBuilder(_theme).build();

  /// Size of each character in the terminal.
  late var _cellSize = _measureCharSize();

  /// Cached device pixel ratio to avoid PlatformDispatcher lookup per cell.
  double _dpr = 1.0;

  void _updateDpr() {
    _dpr = PlatformDispatcher.instance.implicitView?.devicePixelRatio ?? 1.0;
  }

  /// The cached for cells in the terminal. Should be cleared when the same
  /// cell no longer produces the same visual output. For example, when
  /// [_textStyle] is changed, or when the system font changes.
  final _paragraphCache = ParagraphCache(10240);

  TerminalStyle get textStyle => _textStyle;
  TerminalStyle _textStyle;
  set textStyle(TerminalStyle value) {
    if (value == _textStyle) return;
    _textStyle = value;
    _cellSize = _measureCharSize();
    _paragraphCache.clear();
  }

  TextScaler get textScaler => _textScaler;
  TextScaler _textScaler = TextScaler.linear(1.0);
  set textScaler(TextScaler value) {
    if (value == _textScaler) return;
    _textScaler = value;
    _cellSize = _measureCharSize();
    _paragraphCache.clear();
  }

  TerminalTheme get theme => _theme;
  TerminalTheme _theme;
  set theme(TerminalTheme value) {
    if (value == _theme) return;
    _theme = value;
    _colorPalette = PaletteBuilder(value).build();
    _paragraphCache.clear();
  }

  Size _measureCharSize() {
    const test = 'mmmmmmmmmm';

    final textStyle = _textStyle.toTextStyle();
    final builder = ParagraphBuilder(textStyle.getParagraphStyle());
    builder.pushStyle(
      textStyle.getTextStyle(textScaler: _textScaler),
    );
    builder.addText(test);

    final paragraph = builder.build();
    paragraph.layout(ParagraphConstraints(width: double.infinity));

    final result = Size(
      paragraph.maxIntrinsicWidth / test.length,
      paragraph.height,
    );

    paragraph.dispose();
    return result;
  }

  /// The size of each character in the terminal.
  Size get cellSize => _cellSize;

  /// When the set of font available to the system changes, call this method to
  /// clear cached state related to font rendering.
  void clearFontCache() {
    _cellSize = _measureCharSize();
    _paragraphCache.clear();
  }

  /// Paints the cursor based on the current cursor type.
  void paintCursor(
    Canvas canvas,
    Offset offset, {
    required TerminalCursorType cursorType,
    bool hasFocus = true,
  }) {
    final paint = Paint()
      ..color = _theme.cursor
      ..strokeWidth = 1
      ..isAntiAlias = false;

    if (!hasFocus) {
      paint.style = PaintingStyle.stroke;
      canvas.drawRect(offset & _cellSize, paint);
      return;
    }

    switch (cursorType) {
      case TerminalCursorType.block:
        paint.style = PaintingStyle.fill;
        canvas.drawRect(_snapRect(offset & _cellSize), paint);
        return;
      case TerminalCursorType.underline:
        return canvas.drawLine(
          _snapOffset(Offset(offset.dx, offset.dy + _cellSize.height - 1)),
          _snapOffset(
            Offset(
                offset.dx + _cellSize.width, offset.dy + _cellSize.height - 1),
          ),
          paint,
        );
      case TerminalCursorType.verticalBar:
        return canvas.drawLine(
          _snapOffset(offset),
          _snapOffset(Offset(offset.dx, offset.dy + _cellSize.height)),
          paint,
        );
    }
  }

  @pragma('vm:prefer-inline')
  void paintHighlight(Canvas canvas, Offset offset, int length, Color color) {
    final endOffset =
        offset.translate(length * _cellSize.width, _cellSize.height);

    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..isAntiAlias = false;

    canvas.drawRect(
      _snapRect(Rect.fromPoints(offset, endOffset)),
      paint,
    );
  }

  /// Paints [line] to [canvas] at [offset]. The x offset of [offset] is usually
  /// 0, and the y offset is the top of the line.
  void paintLine(
    Canvas canvas,
    Offset offset,
    BufferLine line,
  ) {
    final cellData = _reusableCellData;
    final cellWidth = _cellSize.width;
    final lineOffset = _snapOffset(offset);

    for (var i = 0; i < line.length; i++) {
      line.getCellData(i, cellData);

      final charWidth = cellData.content >> CellContent.widthShift;
      final effectiveCols = charWidth == 2 ? 2 : 1;
      // Snap both edges from the same base to eliminate gaps and overlaps
      // between adjacent cell backgrounds.
      final cellLeft = _snap(lineOffset.dx + i * cellWidth);
      final cellRight = _snap(lineOffset.dx + (i + effectiveCols) * cellWidth);
      final cellOffset = Offset(cellLeft, lineOffset.dy);

      paintCell(canvas, cellOffset, cellData, cellRight);

      if (charWidth == 2) {
        i++;
      }
    }
  }

  @pragma('vm:prefer-inline')
  void paintCell(Canvas canvas, Offset offset, CellData cellData, double rightEdge) {
    paintCellBackground(canvas, offset, cellData, rightEdge);
    paintCellForeground(canvas, offset, cellData, rightEdge);
  }

  /// Paints the character in the cell represented by [cellData] to [canvas] at
  /// [offset].
  @pragma('vm:prefer-inline')
  void paintCellForeground(Canvas canvas, Offset offset, CellData cellData, double rightEdge) {
    final charCode = cellData.content & CellContent.codepointMask;
    if (charCode == 0) return;

    final cellFlags = cellData.flags;

    var color = cellFlags & CellFlags.inverse == 0
        ? resolveForegroundColor(cellData.foreground)
        : resolveBackgroundColor(cellData.background);

    if (cellData.flags & CellFlags.faint != 0) {
      color = color.withOpacity(0.5);
    }

    // Use the actual snapped cell width so lines exactly meet edges.
    final actualWidth = rightEdge - offset.dx;
    final actualHeight = _cellSize.height;

    // Box-drawing characters (U+2500–U+257F) are drawn manually with Canvas
    // primitives to guarantee perfect alignment between adjacent cells,
    // regardless of font metrics.
    if (charCode >= 0x2500 && charCode <= 0x257F) {
      print('[xterm:box] code=0x${charCode.toRadixString(16)} '
          'char=${String.fromCharCode(charCode)} '
          'offset=(${offset.dx.toStringAsFixed(2)},${offset.dy.toStringAsFixed(2)}) '
          'actualW=${actualWidth.toStringAsFixed(2)} nominalW=${_cellSize.width.toStringAsFixed(2)}');
      if (_drawBoxDrawingChar(
        canvas,
        offset,
        charCode,
        color,
        actualWidth,
        actualHeight,
        bold: cellFlags & CellFlags.bold != 0,
      )) {
        return;
      }
    }

    final cacheKey = cellData.getHash() ^ _textScaler.hashCode;
    var paragraph = _paragraphCache.getLayoutFromCache(cacheKey);

    if (paragraph == null) {
      final style = _textStyle.toTextStyle(
        color: color,
        bold: cellFlags & CellFlags.bold != 0,
        italic: cellFlags & CellFlags.italic != 0,
        underline: cellFlags & CellFlags.underline != 0,
      );

      // Flutter does not draw an underline below a space which is not between
      // other regular characters. As only single characters are drawn, this
      // will never produce an underline below a space in the terminal. As a
      // workaround the regular space CodePoint 0x20 is replaced with
      // the CodePoint 0xA0. This is a non breaking space and a underline can be
      // drawn below it.
      var char = String.fromCharCode(charCode);
      if (cellFlags & CellFlags.underline != 0 && charCode == 0x20) {
        char = String.fromCharCode(0xA0);
      }

      paragraph = _paragraphCache.performAndCacheLayout(
        char,
        style,
        _textScaler,
        cacheKey,
      );
    }

    canvas.drawParagraph(paragraph, _snapOffset(offset));
  }

  /// Draws a Unicode box-drawing character (U+2500–U+257F) using Canvas lines.
  /// Returns `true` if the character was handled.
  bool _drawBoxDrawingChar(
    Canvas canvas,
    Offset offset,
    int codePoint,
    Color color,
    double width,
    double height, {
    required bool bold,
  }) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = bold ? 2.0 : 1.0
      ..strokeCap = StrokeCap.butt
      ..isAntiAlias = false;

    final left = offset.dx;
    final right = offset.dx + width;
    final top = offset.dy;
    final bottom = offset.dy + height;
    final midX = offset.dx + width / 2;
    final midY = offset.dy + height / 2;

    // Helper closures for common strokes.
    void hLine(double y, double x1, double x2) {
      canvas.drawLine(Offset(x1, y), Offset(x2, y), paint);
    }

    void vLine(double x, double y1, double y2) {
      canvas.drawLine(Offset(x, y1), Offset(x, y2), paint);
    }

    switch (codePoint) {
      // ─━┄┅┈┉╌╍
      case 0x2500: // ─ light horizontal
        hLine(midY, left, right);
        return true;
      case 0x2501: // ━ heavy horizontal
        hLine(midY, left, right);
        return true;
      case 0x2502: // │ light vertical
        vLine(midX, top, bottom);
        return true;
      case 0x2503: // ┃ heavy vertical
        vLine(midX, top, bottom);
        return true;

      // corners light
      case 0x250C: // ┌ down and right
        hLine(midY, midX, right);
        vLine(midX, midY, bottom);
        return true;
      case 0x2510: // ┐ down and left
        hLine(midY, left, midX);
        vLine(midX, midY, bottom);
        return true;
      case 0x2514: // └ up and right
        hLine(midY, midX, right);
        vLine(midX, top, midY);
        return true;
      case 0x2518: // ┘ up and left
        hLine(midY, left, midX);
        vLine(midX, top, midY);
        return true;

      // corners heavy
      case 0x250F: // ┏ heavy down and right
        hLine(midY, midX, right);
        vLine(midX, midY, bottom);
        return true;
      case 0x2513: // ┓ heavy down and left
        hLine(midY, left, midX);
        vLine(midX, midY, bottom);
        return true;
      case 0x2517: // ┗ heavy up and right
        hLine(midY, midX, right);
        vLine(midX, top, midY);
        return true;
      case 0x251B: // ┛ heavy up and left
        hLine(midY, left, midX);
        vLine(midX, top, midY);
        return true;

      // T-junctions light
      case 0x251C: // ├ vertical and right
        vLine(midX, top, bottom);
        hLine(midY, midX, right);
        return true;
      case 0x2524: // ┤ vertical and left
        vLine(midX, top, bottom);
        hLine(midY, left, midX);
        return true;
      case 0x252C: // ┬ down and horizontal
        hLine(midY, left, right);
        vLine(midX, midY, bottom);
        return true;
      case 0x2534: // ┴ up and horizontal
        hLine(midY, left, right);
        vLine(midX, top, midY);
        return true;
      case 0x253C: // ┼ vertical and horizontal
        hLine(midY, left, right);
        vLine(midX, top, bottom);
        return true;

      // T-junctions heavy
      case 0x2523: // ┣ heavy vertical and right
        vLine(midX, top, bottom);
        hLine(midY, midX, right);
        return true;
      case 0x252B: // ┫ heavy vertical and left
        vLine(midX, top, bottom);
        hLine(midY, left, midX);
        return true;
      case 0x2533: // ┳ heavy down and horizontal
        hLine(midY, left, right);
        vLine(midX, midY, bottom);
        return true;
      case 0x253B: // ┻ heavy up and horizontal
        hLine(midY, left, right);
        vLine(midX, top, midY);
        return true;
      case 0x254B: // ╋ heavy vertical and horizontal
        hLine(midY, left, right);
        vLine(midX, top, bottom);
        return true;

      // double
      case 0x2550: // ═ double horizontal
        hLine(midY - 0.5, left, right);
        hLine(midY + 0.5, left, right);
        return true;
      case 0x2551: // ║ double vertical
        vLine(midX - 0.5, top, bottom);
        vLine(midX + 0.5, top, bottom);
        return true;
      case 0x2554: // ╔ double down and right
        hLine(midY - 0.5, midX, right);
        hLine(midY + 0.5, midX, right);
        vLine(midX - 0.5, midY, bottom);
        vLine(midX + 0.5, midY - 0.5, bottom);
        return true;
      case 0x2557: // ╗ double down and left
        hLine(midY - 0.5, left, midX);
        hLine(midY + 0.5, left, midX);
        vLine(midX - 0.5, midY - 0.5, bottom);
        vLine(midX + 0.5, midY, bottom);
        return true;
      case 0x255A: // ╚ double up and right
        hLine(midY - 0.5, midX, right);
        hLine(midY + 0.5, midX, right);
        vLine(midX - 0.5, top, midY + 0.5);
        vLine(midX + 0.5, top, midY);
        return true;
      case 0x255D: // ╝ double up and left
        hLine(midY - 0.5, left, midX);
        hLine(midY + 0.5, left, midX);
        vLine(midX - 0.5, top, midY);
        vLine(midX + 0.5, top, midY + 0.5);
        return true;
      case 0x2560: // ╠ double vertical and right
        vLine(midX - 0.5, top, bottom);
        vLine(midX + 0.5, top, bottom);
        hLine(midY - 0.5, midX + 0.5, right);
        hLine(midY + 0.5, midX + 0.5, right);
        return true;
      case 0x2563: // ╣ double vertical and left
        vLine(midX - 0.5, top, bottom);
        vLine(midX + 0.5, top, bottom);
        hLine(midY - 0.5, left, midX - 0.5);
        hLine(midY + 0.5, left, midX - 0.5);
        return true;
      case 0x2566: // ╦ double down and horizontal
        hLine(midY - 0.5, left, right);
        hLine(midY + 0.5, left, right);
        vLine(midX - 0.5, midY + 0.5, bottom);
        vLine(midX + 0.5, midY + 0.5, bottom);
        return true;
      case 0x2569: // ╩ double up and horizontal
        hLine(midY - 0.5, left, right);
        hLine(midY + 0.5, left, right);
        vLine(midX - 0.5, top, midY - 0.5);
        vLine(midX + 0.5, top, midY - 0.5);
        return true;
      case 0x256C: // ╬ double cross
        hLine(midY - 0.5, left, right);
        hLine(midY + 0.5, left, right);
        vLine(midX - 0.5, top, bottom);
        vLine(midX + 0.5, top, bottom);
        return true;

      default:
        return false;
    }
  }

  /// Paints the background of a cell represented by [cellData] to [canvas] at
  /// [offset]. [rightEdge] is the pre-snapped x coordinate of the cell's right
  /// boundary, ensuring adjacent cells share the same edge without overlap or
  /// gaps.
  @pragma('vm:prefer-inline')
  void paintCellBackground(Canvas canvas, Offset offset, CellData cellData, double rightEdge) {
    late Color color;
    final colorType = cellData.background & CellColor.typeMask;

    if (cellData.flags & CellFlags.inverse != 0) {
      color = resolveForegroundColor(cellData.foreground);
    } else if (colorType == CellColor.normal) {
      return;
    } else {
      color = resolveBackgroundColor(cellData.background);
    }

    final paint = Paint()
      ..color = color
      ..isAntiAlias = false;
    final y1 = offset.dy + _cellSize.height;
    canvas.drawRect(Rect.fromLTRB(offset.dx, offset.dy, rightEdge, y1), paint);
  }

  double _snap(double value) {
    if (_dpr <= 0) return value;
    return (value * _dpr).roundToDouble() / _dpr;
  }

  Offset _snapOffset(Offset offset) =>
      Offset(_snap(offset.dx), _snap(offset.dy));

  Rect _snapRect(Rect rect) => Rect.fromLTRB(
        _snap(rect.left),
        _snap(rect.top),
        _snap(rect.right),
        _snap(rect.bottom),
      );

  /// Get the effective foreground color for a cell from information encoded in
  /// [cellColor].
  @pragma('vm:prefer-inline')
  Color resolveForegroundColor(int cellColor) {
    final colorType = cellColor & CellColor.typeMask;
    final colorValue = cellColor & CellColor.valueMask;

    switch (colorType) {
      case CellColor.normal:
        return _theme.foreground;
      case CellColor.named:
      case CellColor.palette:
        return _colorPalette[colorValue];
      case CellColor.rgb:
      default:
        return Color(colorValue | 0xFF000000);
    }
  }

  /// Get the effective background color for a cell from information encoded in
  /// [cellColor].
  @pragma('vm:prefer-inline')
  Color resolveBackgroundColor(int cellColor) {
    final colorType = cellColor & CellColor.typeMask;
    final colorValue = cellColor & CellColor.valueMask;

    switch (colorType) {
      case CellColor.normal:
        return _theme.background;
      case CellColor.named:
      case CellColor.palette:
        return _colorPalette[colorValue];
      case CellColor.rgb:
      default:
        return Color(colorValue | 0xFF000000);
    }
  }
}
