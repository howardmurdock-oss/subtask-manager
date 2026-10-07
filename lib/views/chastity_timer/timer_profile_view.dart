import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/chastity_timer_service.dart';
import 'timer_embed_sheet.dart';

/// The player's public page: one link that always shows their current timer.
class TimerProfileView extends StatefulWidget {
  const TimerProfileView({super.key});

  @override
  State<TimerProfileView> createState() => _TimerProfileViewState();
}

class _TimerProfileViewState extends State<TimerProfileView> {
  final _name = TextEditingController();
  bool _busy = false;

  ChastityTimerService get _timers => Provider.of<ChastityTimerService>(context, listen: false);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _snack(String text) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(text), behavior: SnackBarBehavior.floating));

  Future<void> _run(Future<String?> Function() action, {required String done}) async {
    setState(() => _busy = true);
    final error = await action();
    if (!mounted) return;
    setState(() => _busy = false);
    _snack(error == null
        ? done
        : error == 'bad-code'
            ? "That code didn't work. Check it was copied in full."
            : error == 'slow-down'
                ? 'Too many tries just now. Wait a minute, then try again.'
                : "That didn't work. Check your connection and try again.");
  }

  @override
  Widget build(BuildContext context) {
    final timers = Provider.of<ChastityTimerService>(context);
    final profile = timers.profile;
    return Scaffold(
      appBar: AppBar(title: const Text('Your public page')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 12, 16, 24 + MediaQuery.paddingOf(context).bottom),
        children: profile == null ? _setup() : _manage(timers),
      ),
    );
  }

  List<Widget> _setup() => [
        const Text(
          'One link that always shows your current timer - share it once, and it keeps working '
          'from one timer to the next. Visitors can vote on it just like a timer link.',
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _name,
          maxLength: 40,
          decoration: const InputDecoration(
            labelText: 'Name to show (optional)',
            hintText: 'e.g. Toy',
            helperText: 'Shown at the top of the page, to anyone with the link.',
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          icon: const Icon(Icons.public_rounded),
          label: const Text('Make my page'),
          onPressed: _busy
              ? null
              : () => _run(() => _timers.createProfile(name: _name.text.trim().isEmpty ? null : _name.text.trim()),
                  done: 'Your page is ready.'),
        ),
        const SizedBox(height: 24),
        const Divider(),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.download_rounded),
          title: const Text('Already have a page?'),
          subtitle: const Text('Move it here from another device.'),
          onTap: _busy ? null : _import,
        ),
      ];

  List<Widget> _manage(ChastityTimerService timers) {
    final profile = timers.profile!;
    final link = timers.profileLink!;
    final theme = Theme.of(context);
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(link, style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Wrap(spacing: 4, children: [
                TextButton.icon(
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: const Text('Copy'),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: link));
                    _snack('Link copied.');
                  },
                ),
                TextButton.icon(
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: const Text('Open'),
                  onPressed: () => launchUrl(Uri.parse(link), mode: LaunchMode.externalApplication),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.code_rounded, size: 18),
                  label: const Text('Embed'),
                  onPressed: () => showEmbedSheet(context, link, profile: true),
                ),
              ]),
            ],
          ),
        ),
      ),
      const SizedBox(height: 8),
      Text(
        "A timer shows here while its public link is on. A director's timer shows once they "
        'give you its link.',
        style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurface.withValues(alpha: 0.7)),
      ),
      const SizedBox(height: 12),
      Card(
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.badge_rounded),
              title: const Text('Name shown'),
              subtitle: Text(profile.name ?? 'None'),
              trailing: const Icon(Icons.edit_rounded),
              onTap: _busy ? null : () => _editName(profile.name),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.history_rounded),
              value: profile.showHistory,
              onChanged: _busy
                  ? null
                  : (on) => _run(() => _timers.updateProfile(showHistory: on),
                      done: on ? 'Past timers are now shown.' : 'Past timers are now hidden.'),
              title: const Text('Show past timers'),
              subtitle: const Text('When each ended, and how long it ran.'),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      Card(
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.autorenew_rounded),
              title: const Text('New link'),
              subtitle: const Text('If this one has gone further than you want. The old one stops working.'),
              onTap: _busy ? null : _newLink,
            ),
            ListTile(
              leading: const Icon(Icons.upload_rounded),
              title: const Text('Move to another device'),
              subtitle: const Text('Export your page, to take it over on a new phone or computer.'),
              onTap: _busy ? null : _export,
            ),
            ListTile(
              leading: const Icon(Icons.download_rounded),
              title: const Text('Import a page'),
              subtitle: const Text('Take over one exported from another device. This replaces your page here.'),
              onTap: _busy ? null : _import,
            ),
          ],
        ),
      ),
    ];
  }

  Future<void> _editName(String? current) async {
    final controller = TextEditingController(text: current ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Name shown'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(helperText: 'Anyone with the link sees it. Leave empty for none.'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    if (name == null || !mounted) return;
    await _run(() => _timers.updateProfile(name: name.isEmpty ? null : name, clearName: name.isEmpty),
        done: name.isEmpty ? 'No name shown now.' : 'Name saved.');
  }

  Future<void> _newLink() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Make a new link?'),
        content: const Text('The current link, and anything embedded with it, will stop working.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('New link')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _run(_timers.newProfileLink, done: 'New link made. The old one no longer works.');
  }

  Future<void> _export() async {
    final code = _timers.exportProfile();
    if (code == null) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Move your page'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('On the other device, open Your public page and choose Import, then paste this code '
                'or open the saved file.'),
            const SizedBox(height: 10),
            const Text(
              'Keep it private: anyone with it can take your page over. Once it is imported, '
              'this device can no longer change the page.',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            SelectableText(code, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              final path = await FilePicker.saveFile(
                dialogTitle: 'Save your page',
                fileName: 'subtaskmanager-page.txt',
                bytes: utf8.encode(code),
              );
              if (ctx.mounted && path != null) Navigator.pop(ctx);
              if (mounted && path != null) _snack('Saved.');
            },
            child: const Text('Save to a file'),
          ),
          FilledButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: code));
              Navigator.pop(ctx);
              _snack('Code copied.');
            },
            child: const Text('Copy code'),
          ),
        ],
      ),
    );
  }

  Future<void> _import() async {
    final controller = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import a page'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              decoration: const InputDecoration(labelText: 'Code from the other device'),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.folder_open_rounded, size: 18),
                label: const Text('Open a saved file'),
                onPressed: () async {
                  final picked = await FilePicker.pickFiles();
                  final path = picked.isEmpty ? null : picked.single.path;
                  if (path == null) return;
                  try {
                    controller.text = (await File(path).readAsString()).trim();
                  } catch (_) {}
                },
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('Import')),
        ],
      ),
    );
    controller.dispose();
    if (code == null || code.isEmpty || !mounted) return;
    await _run(() => _timers.importProfile(code), done: 'Page imported. It now updates from this device.');
  }
}
