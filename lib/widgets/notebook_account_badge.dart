import 'package:flutter/material.dart';

import '../models/notebook.dart';
import '../services/auth_service.dart';
import '../services/settings_service.dart';
import '../theme/app_theme.dart';

/// A very small, tasteful badge for a notebook card showing which Google
/// account it syncs to: a colored initial avatar for a synced account, or a
/// muted cloud-off glyph for a local-only notebook. Renders **nothing** when no
/// accounts are connected (sync isn't in use, so the badge would just be
/// noise). Long-press shows the full account email.
class NotebookAccountBadge extends StatelessWidget {
  final Notebook notebook;
  final double size;

  const NotebookAccountBadge({
    super.key,
    required this.notebook,
    this.size = 18,
  });

  @override
  Widget build(BuildContext context) {
    final auth = AuthService();
    return ValueListenableBuilder<List<Account>>(
      valueListenable: auth.accounts,
      builder: (context, accounts, _) {
        final palette = Theme.of(context).extension<AppPalette>()!;
        if (accounts.isEmpty) return const SizedBox.shrink();

        if (SettingsService().isNotebookLocalOnly(notebook.id)) {
          return Tooltip(
            message: 'Local only · this device',
            child: Icon(Icons.cloud_off_outlined,
                size: size - 2, color: palette.textDim),
          );
        }

        final targetId = notebook.syncTarget ?? auth.defaultAccountId;
        Account? account;
        for (final a in accounts) {
          if (a.id == targetId) {
            account = a;
            break;
          }
        }
        if (account == null) {
          // Assigned to an account not signed in on this device.
          return Tooltip(
            message: 'Synced to another account',
            child: Icon(Icons.cloud_outlined,
                size: size - 2, color: palette.textDim),
          );
        }

        final label = account.email ?? account.displayName ?? account.id;
        final color = AppPalette.identityColor(account.id);
        return Tooltip(
          message: label,
          child: Container(
            width: size,
            height: size,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.16),
              shape: BoxShape.circle,
              border: Border.all(color: color.withValues(alpha: 0.55)),
            ),
            child: Text(
              _initial(label),
              style: TextStyle(
                fontSize: size * 0.5,
                fontWeight: FontWeight.w700,
                color: color,
                height: 1,
              ),
            ),
          ),
        );
      },
    );
  }

  static String _initial(String s) {
    final t = s.trim();
    return t.isEmpty ? '?' : t.substring(0, 1).toUpperCase();
  }
}
