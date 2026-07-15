import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/server_mode_provider.dart';
import '../screens/server_settings_screen.dart';

/// A compact banner shown at the top of screens when connected to a remote
/// tealkit server.  Tapping opens [ServerSettingsScreen].
class ServerStatusBanner extends ConsumerWidget {
  const ServerStatusBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final modeAsync = ref.watch(serverModeProvider);
    final state = modeAsync.value;
    if (state == null || !state.isRemote) return const SizedBox.shrink();

    final isConnected = state.isConnected;
    final color = isConnected ? Colors.green.shade700 : Colors.orange.shade700;
    final icon = isConnected ? Icons.cloud_done : Icons.cloud_off;
    final label = isConnected
        ? 'Remote server: ${Uri.parse(state.serverUrl).host}'
        : 'Remote server (disconnected)';

    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ServerSettingsScreen()),
      ),
      child: Material(
        color: color.withValues(alpha: 0.12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(Icons.chevron_right, size: 16, color: color),
            ],
          ),
        ),
      ),
    );
  }
}
