import 'package:flutter/material.dart';
import '../models/notebook.dart';
import '../services/auth_service.dart';
import '../services/notebook_service.dart';
import '../services/settings_service.dart';
import '../services/sync_service.dart';
import '../theme/app_theme.dart';

/// Sentinel for the "Local-only (this device)" choice in the picker.
const _kLocalOnly = '__local_only__';

/// Where a brand-new notebook should sync. [accountId] is null when [localOnly].
class NewNotebookTarget {
  final String? accountId;
  final bool localOnly;
  const NewNotebookTarget({this.accountId, this.localOnly = false});
}

/// Decides a new notebook's account (Phase 2 — no implicit default):
/// * 0 accounts → local-only (nothing to sync to).
/// * 1+ accounts → always prompt (each account + Local-only), so the user
///   explicitly chooses even with a single signed-in account.
/// Returns null only if the user cancels the prompt.
Future<NewNotebookTarget?> chooseNewNotebookAccount(BuildContext context) async {
  final accounts = AuthService().accounts.value;
  if (accounts.isEmpty) return const NewNotebookTarget(localOnly: true);
  final selected = await showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('Sync new notebook to…'),
      children: [
        for (final a in accounts)
          _OptionTile(
            icon: Icons.cloud_done_outlined,
            label: a.email ?? a.displayName ?? a.id,
            selected: false,
            onTap: () => Navigator.pop(context, a.id),
          ),
        const Divider(height: 8, indent: 16, endIndent: 16),
        _OptionTile(
          icon: Icons.cloud_off_outlined,
          label: 'Local-only (this device)',
          sublabel: 'Never leaves this device',
          selected: false,
          onTap: () => Navigator.pop(context, _kLocalOnly),
        ),
      ],
    ),
  );
  if (selected == null) return null; // cancelled
  if (selected == _kLocalOnly) return const NewNotebookTarget(localOnly: true);
  return NewNotebookTarget(accountId: selected);
}

/// Shows the per-notebook **"Sync to…"** picker: each connected account, plus
/// "Local-only (this device)". Applies the chosen target (device local-only set
/// and/or synced `syncTarget`) and kicks the appropriate sync. Returns true if
/// anything changed, so the caller can reload its list.
///
/// The chosen account is stored **explicitly** on `syncTarget` (even when it's
/// the current default) so the binding is unambiguous across devices — a null
/// `syncTarget` still means "the default account", but only for notebooks the
/// user never assigned.
Future<bool> showSyncTargetPicker(
  BuildContext context,
  Notebook notebook,
) async {
  final accounts = AuthService().accounts.value;
  final defaultId = AuthService().defaultAccountId;
  final wasLocalOnly = SettingsService().isNotebookLocalOnly(notebook.id);
  final oldTarget = notebook.syncTarget;
  final effectiveTarget = wasLocalOnly ? null : (oldTarget ?? defaultId);

  final selected = await showDialog<String>(
    context: context,
    builder: (context) {
      final palette = Theme.of(context).extension<AppPalette>()!;
      return SimpleDialog(
        title: Text('Sync “${notebook.name}”'),
        children: [
          if (accounts.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
              child: Text(
                'Sign in to sync this notebook to an account.',
                style: TextStyle(fontSize: 13, color: palette.textDim),
              ),
            ),
          for (final a in accounts)
            _OptionTile(
              icon: Icons.cloud_done_outlined,
              label: a.email ?? a.displayName ?? a.id,
              selected: !wasLocalOnly && effectiveTarget == a.id,
              onTap: () => Navigator.pop(context, a.id),
            ),
          if (accounts.isNotEmpty)
            const Divider(height: 8, indent: 16, endIndent: 16),
          _OptionTile(
            icon: Icons.cloud_off_outlined,
            label: 'Local-only (this device)',
            sublabel: 'Never leaves this device',
            selected: wasLocalOnly,
            onTap: () => Navigator.pop(context, _kLocalOnly),
          ),
        ],
      );
    },
  );
  if (selected == null) return false;

  // ── Local-only chosen: pause syncing on this device (no re-key). ──
  if (selected == _kLocalOnly) {
    if (wasLocalOnly) return false;
    if (!context.mounted) return false;
    final ok = await _confirmLocalOnly(context, notebook.name);
    if (ok != true) return false;
    await NotebookService().setNotebookLocalOnly(notebook.id, true);
    return true;
  }

  // ── An account chosen. ──
  final accountId = selected;
  final currentAccount = notebook.syncTarget ?? defaultId;

  // Was disconnected (local-only) on this device → just connect/assign. No
  // re-key: a paused notebook isn't actively colliding on any account.
  if (wasLocalOnly) {
    await NotebookService().setNotebookLocalOnly(notebook.id, false);
    if (notebook.syncTarget != accountId) {
      await NotebookService().setNotebookSyncTarget(notebook.id, accountId);
    }
    SyncService().reenableNotebookSync(notebook.id);
    return true;
  }

  if (currentAccount == accountId) return false; // already synced there

  // Moving between two live accounts → MOVE (re-key + sync-down first so no
  // cloud-only data is lost). This fetches all cloud data, so show progress.
  if (!context.mounted) return false;
  final res = await _runMove(context, notebook.id, accountId);
  if (!res.ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(res.error ?? 'Move failed.'),
      behavior: SnackBarBehavior.floating,
    ));
  }
  return res.ok;
}

/// Runs the account move behind a blocking progress dialog (it fetches all of
/// the notebook's cloud data before re-keying, so it isn't instant).
Future<({bool ok, String? error})> _runMove(
    BuildContext context, String notebookId, String destAccountId) async {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => const AlertDialog(
      content: Row(
        children: [
          SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5)),
          SizedBox(width: 18),
          Expanded(
            child: Text('Moving notebook…\nfetching cloud data first',
                style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
    ),
  );
  final res = await SyncService().moveNotebookToAccount(notebookId, destAccountId);
  if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  return (ok: res.ok, error: res.error);
}

Future<bool?> _confirmLocalOnly(BuildContext context, String name) {
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Keep only on this device?'),
      content: Text(
        '“$name” will stop syncing here. Other devices keep their own copy.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Make local-only'),
        ),
      ],
    ),
  );
}

class _OptionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? sublabel;
  final bool selected;
  final VoidCallback onTap;
  const _OptionTile({
    required this.icon,
    required this.label,
    this.sublabel,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppPalette>()!;
    return ListTile(
      leading: Icon(icon,
          color: selected ? palette.accent : palette.textDim, size: 20),
      title: Text(
        label,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 14,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
      subtitle: sublabel == null
          ? null
          : Text(sublabel!,
              style: TextStyle(fontSize: 11.5, color: palette.textDim)),
      trailing: selected ? Icon(Icons.check, color: palette.accent, size: 20) : null,
      onTap: onTap,
    );
  }
}
