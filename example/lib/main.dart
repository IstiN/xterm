import 'dart:io';

import 'package:example/src/platform_menu.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  _HomeState createState() => _HomeState();
}

class _HomeState extends State<Home> {
  final terminal = Terminal(maxLines: 10000);
  final terminalController = TerminalController();

  @override
  void initState() {
    super.initState();
    _drawBox();
  }

  void _drawBox() {
    // Draw a rounded-corner box to verify box-drawing alignment.
    final buffer = StringBuffer()
      ..write('\u256D\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u256E\r\n')
      ..write('\u2502  hello  \u2502\r\n')
      ..write('\u2502  world  \u2502\r\n')
      ..write('\u2570\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u256F\r\n');
    terminal.write(buffer.toString());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
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
    );
  }
}
