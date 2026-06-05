import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:test/test.dart';
import 'package:xterm/xterm.dart';

@GenerateNiceMocks([MockSpec<EscapeHandler>()])
import 'parser_test.mocks.dart';

void main() {
  group('EscapeParser', () {
    test('can parse window manipulation', () {
      final parser = EscapeParser(MockEscapeHandler());
      parser.write('\x1b[8;24;80t');
      verify(parser.handler.resize(80, 24));
    });

    group('charset designation', () {
      late MockEscapeHandler handler;
      late EscapeParser parser;

      setUp(() {
        handler = MockEscapeHandler();
        parser = EscapeParser(handler);
      });

      test('ESC(B designates G0 as ASCII in single chunk', () {
        parser.write('\x1b(B');
        verify(handler.designateCharset(0, 'B'.codeUnitAt(0)));
      });

      test('ESC(0 designates G0 as DEC Special Graphics in single chunk', () {
        parser.write('\x1b(0');
        verify(handler.designateCharset(0, '0'.codeUnitAt(0)));
      });

      test('ESC)B designates G1 as ASCII in single chunk', () {
        parser.write('\x1b)B');
        verify(handler.designateCharset(1, 'B'.codeUnitAt(0)));
      });

      test('ESC(B across chunk boundary: ESC in chunk1, (B in chunk2', () {
        parser.write('\x1b');
        verifyNever(handler.designateCharset(any, any));
        parser.write('(B');
        verify(handler.designateCharset(0, 'B'.codeUnitAt(0)));
      });

      test('ESC( across chunk boundary: ESC( in chunk1, B in chunk2', () {
        parser.write('\x1b(');
        verifyNever(handler.designateCharset(any, any));
        parser.write('B');
        verify(handler.designateCharset(0, 'B'.codeUnitAt(0)));
      });

      test('ESC(B after SGR reset across chunks', () {
        // Common pattern: ESC[0m ESC(B (reset colors + reset charset)
        parser.write('\x1b[0m\x1b');
        verifyNever(handler.designateCharset(any, any));
        parser.write('(B');
        verify(handler.designateCharset(0, 'B'.codeUnitAt(0)));
      });

      test('ESC(0 then text then ESC(B in single chunk', () {
        parser.write('\x1b(0qqqqq\x1b(B');
        verify(handler.designateCharset(0, '0'.codeUnitAt(0)));
        verify(handler.designateCharset(0, 'B'.codeUnitAt(0)));
      });

      test('no (B text leak after ESC(B', () {
        parser.write('\x1b(B');
        // '(' and 'B' must NOT be written as regular characters
        verifyNever(handler.writeChar('('.codeUnitAt(0)));
        verifyNever(handler.writeChar('B'.codeUnitAt(0)));
      });

      test('no (B text leak when ESC(B split across 3 chunks', () {
        parser.write('\x1b');
        parser.write('(');
        parser.write('B');
        verify(handler.designateCharset(0, 'B'.codeUnitAt(0)));
        verifyNever(handler.writeChar('('.codeUnitAt(0)));
        verifyNever(handler.writeChar('B'.codeUnitAt(0)));
      });

      test('text before and after ESC(B is written correctly', () {
        parser.write('Hello\x1b(BWorld');
        verify(handler.designateCharset(0, 'B'.codeUnitAt(0)));
        verify(handler.writeChar('H'.codeUnitAt(0)));
        verify(handler.writeChar('W'.codeUnitAt(0)));
        verifyNever(handler.writeChar('('.codeUnitAt(0)));
      });
    });
  });
}
