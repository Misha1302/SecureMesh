import 'dart:async';

import 'package:material_ui/material_ui.dart';

/// Stored only inside the unlocked profile. Chat IDs never cross the native
/// notification bridge, including while a generic notification is pending.
class NotificationPreferences {
  const NotificationPreferences({
    this.mutedGroups = const {},
    this.quietUntilMs,
  });
  static const key = 'notificationPreferences';
  final Set<String> mutedGroups;
  final int? quietUntilMs;

  factory NotificationPreferences.fromProfile(Map? profile) {
    final raw = profile?[key];
    if (raw is! Map) return const NotificationPreferences();
    final muted = raw['mutedGroups'];
    final until = raw['quietUntilMs'];
    return NotificationPreferences(
      mutedGroups: muted is List ? muted.whereType<String>().toSet() : const {},
      quietUntilMs: until is int && until > 0 && until <= 8640000000000000
          ? until
          : null,
    );
  }

  bool quietAt(DateTime now) =>
      quietUntilMs != null && now.millisecondsSinceEpoch < quietUntilMs!;
  bool allows(String group, DateTime now) =>
      !quietAt(now) && !mutedGroups.contains(group);
  NotificationPreferences setMute(String group, bool muted) {
    final groups = {...mutedGroups};
    if (muted) {
      groups.add(group);
    } else {
      groups.remove(group);
    }
    return NotificationPreferences(
      mutedGroups: groups,
      quietUntilMs: quietUntilMs,
    );
  }

  NotificationPreferences quietUntil(DateTime? end) => NotificationPreferences(
    mutedGroups: mutedGroups,
    quietUntilMs: end?.millisecondsSinceEpoch,
  );
  Map<String, dynamic> toJson() => {
    'mutedGroups': mutedGroups.toList()..sort(),
    'quietUntilMs': quietUntilMs,
  };
}

class QuietHoursTile extends StatefulWidget {
  const QuietHoursTile({
    super.key,
    required this.preferences,
    required this.russian,
    required this.onChanged,
  });
  final NotificationPreferences preferences;
  final bool russian;
  final ValueChanged<Duration>? onChanged;
  @override
  State<QuietHoursTile> createState() => _QuietHoursTileState();
}

class _QuietHoursTileState extends State<QuietHoursTile> {
  Timer? refresh;
  String tr(String ru, String en) => widget.russian ? ru : en;
  @override
  void initState() {
    super.initState();
    schedule();
  }

  @override
  void didUpdateWidget(QuietHoursTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.preferences.quietUntilMs != widget.preferences.quietUntilMs) {
      schedule();
    }
  }

  void schedule() {
    refresh?.cancel();
    final now = DateTime.now();
    if (!widget.preferences.quietAt(now)) return;
    final until = DateTime.fromMillisecondsSinceEpoch(
      widget.preferences.quietUntilMs!,
    );
    refresh = Timer(until.difference(now), () {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    refresh?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.preferences;
    final until = current.quietAt(DateTime.now())
        ? DateTime.fromMillisecondsSinceEpoch(current.quietUntilMs!)
        : null;
    final label = until == null
        ? tr('Выкл.', 'Off')
        : '${tr('До', 'Until')} ${MaterialLocalizations.of(context).formatShortDate(until)} · ${TimeOfDay.fromDateTime(until).format(context)}';
    return ListTile(
      leading: const Icon(Icons.do_not_disturb_on_outlined),
      title: Text(tr('Не беспокоить', 'Do not disturb')),
      subtitle: Text(label),
      trailing: const Icon(Icons.chevron_right),
      enabled: widget.onChanged != null,
      onTap: widget.onChanged == null
          ? null
          : () async {
              final chosen = await showModalBottomSheet<Duration>(
                context: context,
                builder: (ctx) => SafeArea(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final (hours, name) in [
                        (0, tr('Выключить', 'Turn off')),
                        (1, tr('На 1 час', 'For 1 hour')),
                        (8, tr('На 8 часов', 'For 8 hours')),
                        (24, tr('На 24 часа', 'For 24 hours')),
                      ])
                        ListTile(
                          title: Text(name),
                          onTap: () =>
                              Navigator.pop(ctx, Duration(hours: hours)),
                        ),
                    ],
                  ),
                ),
              );
              if (mounted && chosen != null) widget.onChanged?.call(chosen);
            },
    );
  }
}
