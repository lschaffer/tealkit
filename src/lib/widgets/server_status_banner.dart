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

    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 600;

    final isConnected = state.isConnected;
    final isLight = state.isLightMode;
    final color = isConnected ? Colors.green.shade700 : Colors.orange.shade700;
    final icon = isConnected ? (isLight ? Icons.bolt : Icons.cloud_done) : Icons.cloud_off;
    final serverHost = Uri.parse(state.serverUrl).host;
    final tooltipText = isConnected
        ? (isLight ? 'Connected to TealKit Server Light ($serverHost)' : 'Connected to Remote Server ($serverHost)')
        : 'Remote server (disconnected)';
    final label = isConnected
        ? (isLight ? 'TealKit Server Light: $serverHost' : 'Remote server: $serverHost')
        : 'Remote server (disconnected)';

    // Compact mobile view: show icon with tooltip & LIGHT badge
    if (isMobile) {
      return Tooltip(
        message: tooltipText,
        child: InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const ServerSettingsScreen()),
          ),
          child: Material(
            color: color.withValues(alpha: 0.12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 16, color: color),
                  if (isConnected && isLight) ...[
                    const SizedBox(width: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.amber.shade800,
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: const Text(
                        'LIGHT',
                        style: TextStyle(fontSize: 9, color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    }

    // Full desktop/tablet view
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
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        label,
                        style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isConnected && isLight) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.amber.shade800,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'LIGHT',
                          style: TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ],
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
