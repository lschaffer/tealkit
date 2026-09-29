import 'dart:async';
import 'dart:io';

import 'terminal_printer.dart';

/// Interactive CLI spinner for long-running LLM and tool operations.
class TerminalProgress {
  static const List<String> _frames = [
    '⠋',
    '⠙',
    '⠹',
    '⠸',
    '⠼',
    '⠴',
    '⠦',
    '⠧',
    '⠇',
    '⠏',
  ];

  Timer? _timer;
  int _frameIndex = 0;
  String _message;
  bool _isRunning = false;

  TerminalProgress([this._message = 'Thinking...']);

  /// Whether the spinner is actively animating on the console.
  bool get isRunning => _isRunning;

  /// Starts the animation with an optional custom message.
  void start([String? message]) {
    if (message != null) _message = message;
    if (_isRunning) return;
    if (!stdout.hasTerminal) return;

    _isRunning = true;
    _frameIndex = 0;
    _render();

    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 80), (_) {
      if (!_isRunning) return;
      _frameIndex = (_frameIndex + 1) % _frames.length;
      _render();
    });
  }

  /// Updates the message while continuing animation.
  void update(String message) {
    _message = message;
    if (_isRunning && stdout.hasTerminal) {
      _render();
    }
  }

  /// Clears the spinner from current line without stopping it completely.
  void clear() {
    if (!_isRunning) return;
    if (stdout.hasTerminal) {
      if (TerminalPrinter.supportsAnsi) {
        stdout.write('\r\x1B[2K');
      } else {
        stdout.write('\r${' ' * (_message.length + 6)}\r');
      }
    }
  }

  /// Stops the animation and cleans up line.
  void stop() {
    _isRunning = false;
    _timer?.cancel();
    _timer = null;
    clear();
  }

  void _render() {
    if (!stdout.hasTerminal) return;
    final frame = _frames[_frameIndex];
    if (TerminalPrinter.supportsAnsi) {
      stdout.write('\r\x1B[36m$frame\x1B[0m \x1B[2m$_message\x1B[0m ');
    } else {
      stdout.write('\r$frame $_message ');
    }
  }
}
