import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Notifier to track if the desktop sidebar is open or collapsed.
class SidebarOpenNotifier extends Notifier<bool> {
  @override
  bool build() => true;

  @override
  set state(bool val) => super.state = val;
  
  @override
  bool get state => super.state;
}

final sidebarOpenProvider = NotifierProvider<SidebarOpenNotifier, bool>(SidebarOpenNotifier.new);

class SidebarStickyNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  @override
  set state(bool val) => super.state = val;

  @override
  bool get state => super.state;
}

final sidebarStickyProvider = NotifierProvider<SidebarStickyNotifier, bool>(SidebarStickyNotifier.new);

