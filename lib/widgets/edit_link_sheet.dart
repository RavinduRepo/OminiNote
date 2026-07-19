import 'package:flutter/material.dart';

import '../models/link.dart';
import '../theme/app_theme.dart';
import 'action_sheet.dart';

/// Result of the Edit-link sheet: the (possibly changed) display text and
/// destination; a null [link] means "remove the link" (text stays).
typedef EditLinkResult = ({String text, String? link});

/// The ✎ affordance's editor: display text + destination in one small sheet.
/// Returns null when cancelled. The destination accepts an internal
/// `omninote://link/` URI or any external URL; an empty destination removes
/// the link.
Future<EditLinkResult?> showEditLinkSheet(
  BuildContext context, {
  required String text,
  required String link,
}) {
  return showModalBottomSheet<EditLinkResult>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => scrollableSheetBody(
      sheetContext,
      child: Padding(
        // Keyboard-aware: the sheet's fields must stay above the IME.
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
        ),
        child: _EditLinkForm(text: text, link: link),
      ),
    ),
  );
}

class _EditLinkForm extends StatefulWidget {
  final String text;
  final String link;
  const _EditLinkForm({required this.text, required this.link});

  @override
  State<_EditLinkForm> createState() => _EditLinkFormState();
}

class _EditLinkFormState extends State<_EditLinkForm> {
  late final TextEditingController _text =
      TextEditingController(text: widget.text);
  late final TextEditingController _link =
      TextEditingController(text: widget.link);

  @override
  void dispose() {
    _text.dispose();
    _link.dispose();
    super.dispose();
  }

  void _save() {
    final text = _text.text.trim();
    final link = _link.text.trim();
    Navigator.of(context).pop((
      text: text.isEmpty ? (link.isEmpty ? widget.text : link) : text,
      link: link.isEmpty ? null : link,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppPalette>()!;
    final isInternal = LinkEndpoint.tryParse(widget.link) != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: palette.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Text(
            isInternal ? 'Edit connection link' : 'Edit link',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: palette.textDim,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _text,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Text to show'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _link,
            maxLines: 2,
            minLines: 1,
            style: const TextStyle(fontSize: 12.5),
            decoration: InputDecoration(
              labelText: 'Link to',
              helperText: isInternal
                  ? 'Paste another copied item link to retarget'
                  : null,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              TextButton(
                onPressed: () => Navigator.of(context)
                    .pop((text: _text.text.trim(), link: null)),
                child: Text(
                  'Remove link',
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 6),
              FilledButton(onPressed: _save, child: const Text('Save')),
            ],
          ),
        ],
      ),
    );
  }
}
