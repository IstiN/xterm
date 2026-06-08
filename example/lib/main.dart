import 'dart:convert';
import 'dart:io';

import 'package:example/src/platform_menu.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';

void main() {
  runApp(MyApp());
}

bool get isDesktop {
  if (kIsWeb) return false;
  return [
    TargetPlatform.windows,
    TargetPlatform.linux,
    TargetPlatform.macOS,
  ].contains(defaultTargetPlatform);
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'xterm.dart demo',
      debugShowCheckedModeBanner: false,
      home: AppPlatformMenu(child: Home()),
    );
  }
}

class Home extends StatefulWidget {
  Home({super.key});

  @override
  HomeState createState() => HomeState();
}

class HomeState extends State<Home> {
  final terminal = Terminal(maxLines: 10000);
  final terminalController = TerminalController();

  late final Pty pty;

  double _scale = 1.0;
  static const double _baseWidth = 800;
  static const double _baseHeight = 600;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.endOfFrame.then(
      (_) {
        if (mounted) _startPty();
      },
    );
  }

  void _startPty() {
    // Print a box-drawing demo before the shell starts.
    terminal.write(
      '\u256D\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u256E\r\n'
      '\u2502  hello  \u2502\r\n'
      '\u2570\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u256F\r\n'
      '\r\n',
    );

    pty = Pty.start(
      shell,
      columns: terminal.viewWidth,
      rows: terminal.viewHeight,
    );

    pty.output
        .cast<List<int>>()
        .transform(Utf8Decoder())
        .listen(terminal.write);

    pty.exitCode.then((code) {
      terminal.write('the process exited with exit code $code');
    });

    terminal.onOutput = (data) {
      pty.write(const Utf8Encoder().convert(data));
    };

    terminal.onResize = (w, h, pw, ph) {
      pty.resize(h, w);
    };
  }

  void _setScale(double value) {
    setState(() {
      _scale = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: Transform.scale(
                scale: _scale,
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: _baseWidth,
                  height: _baseHeight,
                  child: TerminalView(
                    terminal,
                    controller: terminalController,
                    autofocus: true,
                    backgroundOpacity: 0.7,
                    onSecondaryTapDown: (details, offset) async {
                      final selection = terminalController.selection;
                      if (selection != null) {
                        final text = terminal.buffer.getText(selection);
                        terminalController.clearSelection();
                        await Clipboard.setData(ClipboardData(text: text));
                      } else {
                        final data = await Clipboard.getData('text/plain');
                        final text = data?.text;
                        if (text != null) {
                          terminal.paste(text);
                        }
                      }
                    },
                  ),
                ),
              ),
            ),
            Positioned(
              top: 8,
              left: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'Scale: ${_scale.toStringAsFixed(2)}x  |  '
                  'Base: ${_baseWidth.toInt()}x${_baseHeight.toInt()}  |  '
                  'Rendered: ${(_baseWidth * _scale).toInt()}x${(_baseHeight * _scale).toInt()}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final s in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
            FloatingActionButton.small(
              heroTag: 'scale_$s',
              backgroundColor:
                  _scale == s ? Colors.blue : Colors.grey.shade800,
              onPressed: () => _setScale(s),
              child: Text(
                '${s}x',
                style: const TextStyle(fontSize: 10, color: Colors.white),
              ),
            ),
        ],
      ),
    );
  }
}

String get shell {
  if (Platform.isMacOS || Platform.isLinux) {
    return Platform.environment['SHELL'] ?? 'bash';
  }

  if (Platform.isWindows) {
    return 'cmd.exe';
  }

  return 'sh';
}
