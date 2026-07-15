import 'dart:async';

class ServerLiveLog {
  static final Map<String, List<String>> _logs = {};

  static void start(String taskId) {
    _logs[taskId] = [];
  }

  static void log(String taskId, String message) {
    final list = _logs[taskId];
    if (list != null) {
      final stamp = DateTime.now().toLocal().toIso8601String().substring(11, 19);
      final msg = message.replaceAll('\r\n', '\n').trim();
      list.add('[$stamp] $msg');
    }
  }

  static List<String> get(String taskId) {
    return _logs[taskId] ?? const [];
  }

  static void end(String taskId) {
    // Keep it for 60 seconds after completion so the client has time to fetch final logs
    Timer(const Duration(seconds: 60), () {
      _logs.remove(taskId);
    });
  }
}
