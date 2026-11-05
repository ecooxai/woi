import 'package:flutter/material.dart';

import 'android_bridge.dart';

/// Woi's accessibility service as WoiA11yKeeper.kt sees it.
class AccessibilityStatus {
  const AccessibilityStatus({
    required this.enabled,
    required this.bound,
    required this.canSelfEnable,
    required this.batteryExempt,
  });

  /// Listed in enabled_accessibility_services.
  final bool enabled;

  /// The service is connected (screen control works).
  final bool bound;

  /// WRITE_SECURE_SETTINGS granted: Woi switches the service back on itself.
  final bool canSelfEnable;
  final bool batteryExempt;

  static Future<AccessibilityStatus?> load() async {
    try {
      final m = await AndroidBridge.instance.call<Map<Object?, Object?>>('accessibilityStatus');
      if (m == null) return null;
      return AccessibilityStatus(
        enabled: m['enabled'] == true,
        bound: m['bound'] == true,
        canSelfEnable: m['canSelfEnable'] == true,
        batteryExempt: m['batteryExempt'] == true,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Settings → Android: accessibility state, with buttons to open the system
/// accessibility page and to ask for the battery-optimization exemption.
class AndroidAccessibilityPanel extends StatefulWidget {
  const AndroidAccessibilityPanel({super.key});

  @override
  State<AndroidAccessibilityPanel> createState() => _AndroidAccessibilityPanelState();
}

class _AndroidAccessibilityPanelState extends State<AndroidAccessibilityPanel> with WidgetsBindingObserver {
  AccessibilityStatus? _s;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final s = await AccessibilityStatus.load();
    if (mounted) setState(() => _s = s);
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    if (s == null) return const Text('Checking…');
    final state = s.bound
        ? 'On'
        : s.enabled
        ? 'Switched on, connecting…'
        : 'Off';
    final keep = s.canSelfEnable
        ? 'Woi switches it back on by itself.'
        : 'To keep it on after updates: adb shell pm grant dev.woi.woi android.permission.WRITE_SECURE_SETTINGS';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$state. $keep'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (!s.bound)
              OutlinedButton(
                onPressed: () => AndroidBridge.instance.call<bool>('a11yOpenSettings'),
                child: const Text('Accessibility settings'),
              ),
            if (!s.batteryExempt)
              OutlinedButton(
                onPressed: () async {
                  await AndroidBridge.instance.call<bool>('requestBatteryExemption');
                },
                child: const Text('Allow running in background'),
              ),
          ],
        ),
      ],
    );
  }
}
