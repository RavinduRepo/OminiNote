import 'package:flutter/material.dart';

import '../models/notebook.dart';
import '../services/auth_service.dart';
import '../services/settings_service.dart';
import '../theme/app_theme.dart';

/// A tiny, non-distracting badge showing which Google account a notebook syncs
/// to: the account's **profile photo** ringed in that account's identity color
/// (so two accounts are told apart at a glance — by picture and by color, not
/// just an initial). Falls back to a solid color dot when there's no photo, a
/// muted cloud-off glyph for local-only, and renders **nothing** when no
/// accounts are connected. Long-press shows the full account email.
class NotebookAccountBadge extends StatelessWidget {
  final Notebook notebook;

  /// Outer diameter. Deliberately small — this is an ambient indicator.
  final double size;

  const NotebookAccountBadge({
    super.key,
    required this.notebook,
    this.size = 15,
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
                size: size, color: palette.textDim),
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
          return Tooltip(
            message: 'Synced to another account',
            child:
                Icon(Icons.cloud_outlined, size: size, color: palette.textDim),
          );
        }

        final label = account.email ?? account.displayName ?? account.id;
        final color = AppPalette.identityColor(account.id);
        final photo = account.photoUrl;

        // Colored ring (identity color) around the round profile photo — the
        // color is the quick identifier, the photo the precise one.
        return Tooltip(
          message: label,
          child: Container(
            width: size,
            height: size,
            padding: const EdgeInsets.all(1.4),
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: ClipOval(
              child: (photo == null || photo.isEmpty)
                  ? Container(color: color.withValues(alpha: 0.35))
                  : Image.network(
                      photo,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      errorBuilder: (_, _, _) =>
                          Container(color: color.withValues(alpha: 0.35)),
                    ),
            ),
          ),
        );
      },
    );
  }
}
