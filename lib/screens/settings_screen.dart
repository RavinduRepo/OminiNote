import 'package:flutter/material.dart';
import '../models/canvas_page.dart';
import '../services/auth_service.dart';
import '../services/settings_service.dart';
import '../services/sync_service.dart';
import '../theme/app_theme.dart';
import '../widgets/sync_status_icon.dart';
import 'bin_screen.dart';

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
      appBar: AppBar(
        title: const Text('Settings'),
        actions: const [SyncStatusIcon(), SizedBox(width: 12)],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        children: [
          const _SectionLabel('Account'),
          _Card(child: _AccountSection()),
          const SizedBox(height: 24),
          const _SectionLabel('Storage'),
          _Card(child: _StorageSection()),
          const SizedBox(height: 24),
          const _SectionLabel('Recycle bin'),
          _Card(
            child: ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Deleted items'),
              subtitle: const Text(
                'Restore notebooks, sections and canvases · kept 30 days',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const BinScreen()),
              ),
            ),
          ),
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
            child: ValueListenableBuilder<bool>(
              valueListenable: settings.autoPageColor,
              builder: (context, isAuto, _) =>
                  ValueListenableBuilder<PageBackground>(
                valueListenable: settings.defaultPageBackground,
                builder: (context, bg, _) => _DefaultPageSection(
                  background: bg,
                  isAuto: isAuto,
                  onChanged: settings.setDefaultPageBackground,
                  onSetAuto: () => settings.setAutoPageColor(true),
                ),
              ),
            ),
          ),
        ],
          ),
        ),
      ),
    );
  }
}

// ── Account Section ──────────────────────────────────────────────────────────

class _AccountSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: AuthService().account,
      builder: (context, account, _) {
        if (account == null) {
          return _SignedOutRow();
        }
        return _SignedInRow(account: account);
      },
    );
  }
}

class _SignedOutRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppPalette>()!;
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
                  'Sign in to sync notebooks across devices',
                  style: TextStyle(fontSize: 12.5, color: palette.textDim),
                ),
              ],
            ),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: AuthService().signingIn,
            builder: (context, busy, _) => busy
                ? const SizedBox(
                    width: 36,
                    height: 36,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : OutlinedButton.icon(
                    onPressed: () async {
                      final acct = await AuthService().signIn();
                      if (acct == null && context.mounted) {
                        final err =
                            AuthService().lastError.value ?? 'Sign-in failed';
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(err), behavior: SnackBarBehavior.floating),
                        );
                      }
                    },
                    icon: const Icon(Icons.login, size: 18),
                    label: const Text('Sign in'),
                  ),
          ),
        ],
      ),
    );
  }
}

class _SignedInRow extends StatelessWidget {
  final dynamic account; // GoogleSignInAccount
  const _SignedInRow({required this.account});

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppPalette>()!;
    final photoUrl = account.photoUrl as String?;
    final displayName = account.displayName as String? ?? '';
    final email = account.email as String? ?? '';

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          CircleAvatar(
            radius: 20,
            backgroundImage: photoUrl != null ? NetworkImage(photoUrl) : null,
            backgroundColor: palette.accentSoft,
            child: photoUrl == null
                ? Text(
                    displayName.isNotEmpty ? displayName[0].toUpperCase() : '?',
                    style: TextStyle(
                      color: palette.accent,
                      fontWeight: FontWeight.bold,
                    ),
                  )
                : null,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayName.isNotEmpty ? displayName : email,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600),
                ),
                if (displayName.isNotEmpty)
                  Text(
                    email,
                    style: TextStyle(fontSize: 12.5, color: palette.textDim),
                  ),
              ],
            ),
          ),
          TextButton(
            onPressed: () async {
              await AuthService().signOut();
            },
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
  }
}

// ── Storage Section ──────────────────────────────────────────────────────────

class _StorageSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: AuthService().account,
      builder: (context, account, _) {
        final connected = account != null;
        return Column(
          children: [
            _StorageTile(
              icon: Icons.folder_outlined,
              title: 'This device',
              subtitle: 'Notebooks stored locally',
              selected: true,
              onTap: null,
            ),
            const Divider(height: 1),
            _StorageTile(
              icon: Icons.cloud_outlined,
              title: 'Google Drive',
              subtitle: connected
                  ? _syncSubtitle()
                  : 'Sign in above to enable sync',
              selected: connected,
              trailing: connected ? _SyncStatusChip() : null,
              onTap: connected
                  ? () => SyncService().syncNow()
                  : null,
            ),
            if (connected) ...[
              const Divider(height: 1),
              _StorageTile(
                icon: Icons.sync_problem_outlined,
                title: 'Repair sync',
                subtitle: 'Re-download and reconcile everything from Drive',
                selected: false,
                onTap: () {
                  SyncService().repair();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Repairing sync…'),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                },
              ),
            ],
          ],
        );
      },
    );
  }

  String _syncSubtitle() {
    final t = SettingsService().lastSyncAt;
    if (t == null) return 'Tap to sync now';
    final diff = DateTime.now().difference(t);
    if (diff.inSeconds < 60) return 'Synced just now — tap to sync again';
    if (diff.inMinutes < 60) return 'Synced ${diff.inMinutes}m ago — tap to sync';
    return 'Synced ${diff.inHours}h ago — tap to sync';
  }
}

class _SyncStatusChip extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppPalette>()!;
    return ValueListenableBuilder<SyncStatus>(
      valueListenable: SyncService().status,
      builder: (context, status, _) {
        final (label, color) = switch (status) {
          SyncStatus.syncing => ('Syncing…', palette.accent),
          SyncStatus.error => ('Error', Colors.redAccent),
          SyncStatus.offline => ('Offline', palette.textDim),
          SyncStatus.idle => ('Synced', Colors.green.shade600),
        };
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: color.withAlpha(30),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        );
      },
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

// ── Default page section ─────────────────────────────────────────────────────

/// App-wide default page color + pattern for new sections/pages.
class _DefaultPageSection extends StatelessWidget {
  final PageBackground background;
  final bool isAuto;
  final ValueChanged<PageBackground> onChanged;
  final VoidCallback onSetAuto;

  const _DefaultPageSection({
    required this.background,
    required this.isAuto,
    required this.onChanged,
    required this.onSetAuto,
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
    final primary = theme.colorScheme.primary;
    final divider = theme.dividerColor;
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
              // Auto swatch — half white / half dark, shows theme-adaptive color
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: GestureDetector(
                  onTap: onSetAuto,
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isAuto ? primary : divider,
                        width: isAuto ? 3 : 1,
                      ),
                    ),
                    child: ClipOval(
                      child: CustomPaint(painter: _HalfAndHalfPainter()),
                    ),
                  ),
                ),
              ),
              for (final preset in _presets)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: GestureDetector(
                    onTap: () => onChanged(background.copyWith(color: preset)),
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: preset,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: !isAuto &&
                                  background.color.toARGB32() ==
                                      preset.toARGB32()
                              ? primary
                              : divider,
                          width: !isAuto &&
                                  background.color.toARGB32() ==
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

// ── Theme section ────────────────────────────────────────────────────────────

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

// ── Half-and-half painter for Auto page color swatch ─────────────────────────

class _HalfAndHalfPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    // Light half (top-left triangle)
    paint.color = const Color(0xFFFFFFFF);
    canvas.drawPath(
      Path()
        ..moveTo(0, 0)
        ..lineTo(size.width, 0)
        ..lineTo(0, size.height)
        ..close(),
      paint,
    );
    // Dark half (bottom-right triangle)
    paint.color = const Color(0xFF2A2A2E);
    canvas.drawPath(
      Path()
        ..moveTo(size.width, 0)
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height)
        ..close(),
      paint,
    );
  }

  @override
  bool shouldRepaint(_HalfAndHalfPainter old) => false;
}

// ── Shared widgets ────────────────────────────────────────────────────────────

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<AppPalette>()!;
    return Material(
      color: theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(kRadius + 2),
      clipBehavior: Clip.antiAlias,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(kRadius + 2),
          border: Border.all(color: palette.border),
        ),
        child: child,
      ),
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
