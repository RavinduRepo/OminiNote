import 'package:flutter/material.dart';
import '../models/canvas_page.dart';
import '../services/settings_service.dart';
import '../theme/app_theme.dart';

/// Mobile (single-pane) vs desktop (split-view sidebar) shell, or auto-detect
/// from window width.
class _LayoutSection extends StatelessWidget {
  final LayoutMode current;
  final ValueChanged<LayoutMode> onChanged;

  const _LayoutSection({required this.current, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppPalette>()!;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<LayoutMode>(
              segments: const [
                ButtonSegment(
                  value: LayoutMode.auto,
                  icon: Icon(Icons.devices_outlined),
                  label: Text('Auto'),
                ),
                ButtonSegment(
                  value: LayoutMode.mobile,
                  icon: Icon(Icons.smartphone_outlined),
                  label: Text('Mobile'),
                ),
                ButtonSegment(
                  value: LayoutMode.desktop,
                  icon: Icon(Icons.laptop_outlined),
                  label: Text('Desktop'),
                ),
              ],
              selected: {current},
              showSelectedIcon: false,
              onSelectionChanged: (selection) => onChanged(selection.first),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Auto picks Mobile or Desktop based on the window size.',
            style: TextStyle(fontSize: 12, color: palette.textDim),
          ),
        ],
      ),
    );
  }
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService();

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        children: [
          const _SectionLabel('Account'),
          _Card(child: _AccountSection()),
          const SizedBox(height: 24),
          const _SectionLabel('Storage'),
          _Card(child: _StorageSection()),
          const SizedBox(height: 24),
          const _SectionLabel('Appearance'),
          _Card(
            child: ValueListenableBuilder<ThemeMode>(
              valueListenable: settings.themeMode,
              builder: (context, mode, _) => _ThemeSection(
                current: mode,
                onChanged: settings.setThemeMode,
              ),
            ),
          ),
          const SizedBox(height: 24),
          const _SectionLabel('Layout'),
          _Card(
            child: ValueListenableBuilder<LayoutMode>(
              valueListenable: settings.layoutMode,
              builder: (context, mode, _) => _LayoutSection(
                current: mode,
                onChanged: settings.setLayoutMode,
              ),
            ),
          ),
          const SizedBox(height: 24),
          const _SectionLabel('Default page'),
          _Card(
            child: ValueListenableBuilder<PageBackground>(
              valueListenable: settings.defaultPageBackground,
              builder: (context, bg, _) => _DefaultPageSection(
                background: bg,
                onChanged: settings.setDefaultPageBackground,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// App-wide default page color + pattern for new sections/pages.
class _DefaultPageSection extends StatelessWidget {
  final PageBackground background;
  final ValueChanged<PageBackground> onChanged;

  const _DefaultPageSection({
    required this.background,
    required this.onChanged,
  });

  static const _presets = [
    Color(0xFFFFFFFF), // white
    Color(0xFFF8F1E3), // cream
    Color(0xFFEDEDED), // light grey
    Color(0xFF2A2A2E), // charcoal
    Color(0xFF17171A), // near black
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Color',
            style: TextStyle(
              fontSize: 12.5,
              color: theme.extension<AppPalette>()!.textDim,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              for (final preset in _presets)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: GestureDetector(
                    onTap: () =>
                        onChanged(background.copyWith(color: preset)),
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: preset,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: background.color.toARGB32() ==
                                  preset.toARGB32()
                              ? theme.colorScheme.primary
                              : theme.dividerColor,
                          width: background.color.toARGB32() ==
                                  preset.toARGB32()
                              ? 3
                              : 1,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            'Pattern',
            style: TextStyle(
              fontSize: 12.5,
              color: theme.extension<AppPalette>()!.textDim,
            ),
          ),
          const SizedBox(height: 10),
          SegmentedButton<BgPattern>(
            segments: const [
              ButtonSegment(value: BgPattern.blank, label: Text('Blank')),
              ButtonSegment(value: BgPattern.ruled, label: Text('Ruled')),
              ButtonSegment(value: BgPattern.grid, label: Text('Grid')),
              ButtonSegment(value: BgPattern.dotted, label: Text('Dotted')),
            ],
            selected: {background.pattern},
            showSelectedIcon: false,
            onSelectionChanged: (s) =>
                onChanged(background.copyWith(pattern: s.first)),
          ),
        ],
      ),
    );
  }
}

class _AccountSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<AppPalette>()!;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: palette.accentSoft,
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.person_outline, color: palette.accent),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Not signed in',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  'Sign in to sync notebooks',
                  style: TextStyle(fontSize: 12.5, color: palette.textDim),
                ),
              ],
            ),
          ),
          OutlinedButton.icon(
            onPressed: () => _showComingSoon(context, 'Google sign-in'),
            icon: const Icon(Icons.login, size: 18),
            label: const Text('Sign in'),
          ),
        ],
      ),
    );
  }
}

class _StorageSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _StorageTile(
          icon: Icons.folder_outlined,
          title: 'This device',
          subtitle: 'Notebooks are stored locally',
          selected: true,
          onTap: null,
        ),
        const Divider(height: 1),
        _StorageTile(
          icon: Icons.cloud_outlined,
          title: 'Google Drive',
          subtitle: 'Back up and sync across devices',
          selected: false,
          trailing: const _SoonChip(),
          onTap: () => _showComingSoon(context, 'Google Drive sync'),
        ),
      ],
    );
  }
}

class _StorageTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _StorageTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<AppPalette>()!;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Icon(icon, color: selected ? palette.accent : palette.textDim),
      title: Text(
        title,
        style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(fontSize: 12.5, color: palette.textDim),
      ),
      trailing:
          trailing ??
          (selected
              ? Icon(Icons.check_circle, color: palette.accent, size: 20)
              : null),
      onTap: onTap,
    );
  }
}

class _ThemeSection extends StatelessWidget {
  final ThemeMode current;
  final ValueChanged<ThemeMode> onChanged;

  const _ThemeSection({required this.current, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: SizedBox(
        width: double.infinity,
        child: SegmentedButton<ThemeMode>(
          segments: const [
            ButtonSegment(
              value: ThemeMode.system,
              icon: Icon(Icons.brightness_auto_outlined),
              label: Text('System'),
            ),
            ButtonSegment(
              value: ThemeMode.light,
              icon: Icon(Icons.light_mode_outlined),
              label: Text('Light'),
            ),
            ButtonSegment(
              value: ThemeMode.dark,
              icon: Icon(Icons.dark_mode_outlined),
              label: Text('Dark'),
            ),
          ],
          selected: {current},
          showSelectedIcon: false,
          onSelectionChanged: (selection) => onChanged(selection.first),
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<AppPalette>()!;
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(kRadius + 2),
        border: Border.all(color: palette.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppPalette>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 11,
          letterSpacing: 0.8,
          fontWeight: FontWeight.w600,
          color: palette.textDim,
        ),
      ),
    );
  }
}

class _SoonChip extends StatelessWidget {
  const _SoonChip();

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppPalette>()!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: palette.accentSoft,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        'Soon',
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: palette.accent,
        ),
      ),
    );
  }
}

void _showComingSoon(BuildContext context, String feature) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('$feature is coming soon'),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
