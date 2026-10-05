import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/chastity_timer.dart';
import '../../models/partner_contact.dart';
import '../../services/chastity_timer_service.dart';
import '../../services/partner_service.dart';
import '../../services/sync_service.dart';
import 'timer_format.dart';
import 'timer_setup_view.dart' show showDurationDialog;

/// One timer: the countdown, the changes this side may make, the
/// combination, the public link and the history.
class TimerDetailView extends StatefulWidget {
  const TimerDetailView({super.key, required this.timerId});

  final String timerId;

  @override
  State<TimerDetailView> createState() => _TimerDetailViewState();
}

class _TimerDetailViewState extends State<TimerDetailView> {
  Timer? _tick;
  Timer? _poll;
  bool _busy = false;

  ChastityTimerService get _timers =>
      Provider.of<ChastityTimerService>(context, listen: false);

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    // Strangers and the random schedule change it without a nudge; look
    // again now and then while it is on screen.
    _poll = Timer.periodic(
        const Duration(seconds: 30), (_) => _timers.refresh(widget.timerId));
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _timers.refresh(widget.timerId));
  }

  @override
  void dispose() {
    _tick?.cancel();
    _poll?.cancel();
    super.dispose();
  }

  PartnerContact? _partnerOf(TimerRecord record) {
    final code = record.partnerCode;
    if (code == null || code.isEmpty) return null;
    return Provider.of<PartnerService>(context, listen: false)
        .findContactByCode(code);
  }

  void _snack(String text) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), behavior: SnackBarBehavior.floating));

  /// Runs [action]; on success tells the partner, with [summary] unless the
  /// timer hides amounts from the player.
  Future<void> _run(Future<String?> Function() action,
      {required String done, String? partnerSummary}) async {
    setState(() => _busy = true);
    final error = await action();
    if (!mounted) return;
    setState(() => _busy = false);
    if (error != null) {
      _snack(describeTimerError(error));
      return;
    }
    _snack(done);
    final record = _timers.recordOf(widget.timerId);
    final partner = record == null ? null : _partnerOf(record);
    if (partner != null) {
      Provider.of<SyncService>(context, listen: false)
          .notifyTimerChanged(partner, widget.timerId, summary: partnerSummary);
    }
  }

  Future<void> _change(ChastityTimerView view,
      {required bool add, Duration? amount}) async {
    final picked = amount ??
        await showDurationDialog(context,
            title: add ? 'Add time' : 'Remove time');
    if (picked == null || picked == Duration.zero || !mounted) return;
    final signed = add ? picked : -picked;
    final hiddenFromPlayer =
        view.config.hidden && view.role == TimerRole.director;
    final who =
        view.role == TimerRole.director ? 'Your director' : 'Your player';
    await _run(
      () => _timers.adjust(widget.timerId, signed),
      done: '${add ? 'Added' : 'Removed'} ${formatSpan(picked)}.',
      partnerSummary: hiddenFromPlayer
          ? '$who changed your timer.'
          : '$who ${add ? 'added' : 'removed'} ${formatSpan(picked)}.',
    );
  }

  Future<void> _release(ChastityTimerView view) async {
    if (view.role == TimerRole.player && view.playerMayEnd) {
      final hasPartner = _timers.recordOf(widget.timerId)?.partnerCode != null;
      final end = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('End your timer?'),
          content: Text('This ends it and shows the combination, if there is one.'
              '${hasPartner ? ' Your director will be told.' : ''}'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('End timer')),
          ],
        ),
      );
      if (end != true) return;
      await _run(
        () => _timers.release(widget.timerId),
        done: 'Timer ended.',
        partnerSummary: 'Your player ended their timer.',
      );
      return;
    }
    final isPlayer = view.role == TimerRole.player;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isPlayer ? 'Emergency release?' : 'End the timer now?'),
        content: Text(isPlayer
            ? 'This ends the timer straight away and shows the combination, if there is one. '
                'It cannot be undone, and your director will be told.'
            : 'This ends the timer straight away and shows the player the combination, if there is one. '
                'It cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(isPlayer ? 'Release now' : 'End now'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run(
      () => _timers.release(widget.timerId),
      done: isPlayer ? 'Released.' : 'Timer ended.',
      partnerSummary: isPlayer
          ? 'Your player used the emergency release.'
          : 'Your director ended your timer early.',
    );
  }

  Future<void> _togglePublic(ChastityTimerView view, bool on) => _run(
        () => _timers.configure(widget.timerId, {
          'public': {...view.config.publicLink.toJson(), 'enabled': on},
        }),
        done: on ? 'Public link switched on.' : 'Public link switched off.',
      );

  @override
  Widget build(BuildContext context) {
    final timers = Provider.of<ChastityTimerService>(context);
    final record = timers.recordOf(widget.timerId);
    final view = timers.viewOf(widget.timerId);
    final theme = Theme.of(context);

    // Looking at a finished timer is seeing how it ended.
    if (view != null && timers.needsAttention(widget.timerId)) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => timers.acknowledge(widget.timerId));
    }

    if (record == null) {
      return Scaffold(
          appBar: AppBar(),
          body: const Center(
              child: Text('This timer is no longer on this device.')));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(record.partnerName == null
            ? 'My timer'
            : record.role == TimerRole.director
                ? 'Timer for ${record.partnerName}'
                : 'Timer with ${record.partnerName}'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v != 'forget') return;
              await timers.forget(widget.timerId);
              if (context.mounted) Navigator.of(context).pop();
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'forget',
                enabled: view?.isOver ?? true,
                child: const Text('Remove from this device'),
              ),
            ],
          ),
        ],
      ),
      body: view == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    TextButton(
                        onPressed: () => timers.refresh(widget.timerId),
                        child: const Text('Try again')),
                  ],
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: () => timers.refresh(widget.timerId),
              child: ListView(
                // Room for the system navigation bar: Android draws the app behind it.
                padding: EdgeInsets.fromLTRB(
                    16, 12, 16, 32 + MediaQuery.paddingOf(context).bottom),
                children: [
                  _countdownCard(view, theme),
                  const SizedBox(height: 12),
                  if (view.isManager && view.partnerConnected == false && record.partnerCode != null && !view.isOver) ...[
                    _notReceivedCard(record, theme),
                    const SizedBox(height: 12),
                  ],
                  if (!view.isOver) _actionsCard(view, theme),
                  if (view.config.combinationEnabled) ...[
                    const SizedBox(height: 12),
                    _combinationCard(view, theme),
                  ],
                  if (view.isManager || view.config.publicLink.enabled) ...[
                    const SizedBox(height: 12),
                    _publicCard(view, theme),
                  ],
                  const SizedBox(height: 12),
                  _historyCard(view, record, theme),
                ],
              ),
            ),
    );
  }

  /// The partner has never opened this timer - most likely its key never
  /// reached them (their phone asleep, in battery saver). A fresh one can be
  /// sent; the server refuses once they have connected.
  Widget _notReceivedCard(TimerRecord record, ThemeData theme) {
    final name = record.partnerName ?? 'Your partner';
    return Card(
      color: Colors.amber.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.sync_problem_rounded, color: Colors.amber),
                const SizedBox(width: 10),
                Expanded(
                  child: Text("$name hasn't received this timer yet",
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Their phone may have been asleep or in battery saver when you started it. '
              'Send it again, then have them open the app.',
              style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurface.withValues(alpha: 0.75)),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                icon: const Icon(Icons.send_rounded, size: 18),
                label: const Text('Send again'),
                onPressed: _busy ? null : () => _sendAgain(record),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _sendAgain(TimerRecord record) async {
    final partner = _partnerOf(record);
    if (partner == null) {
      _snack("${record.partnerName ?? 'That partner'} isn't in your contacts any more.");
      return;
    }
    setState(() => _busy = true);
    final result = await _timers.reissuePartnerKey(widget.timerId);
    if (!mounted) return;
    if (result.key == null) {
      setState(() => _busy = false);
      _snack(describeTimerError(result.error));
      await _timers.refresh(widget.timerId);
      return;
    }
    final sent = await Provider.of<SyncService>(context, listen: false).shareTimer(
      partner,
      timerId: widget.timerId,
      key: result.key!,
      theirRole: record.role == TimerRole.player ? TimerRole.director : TimerRole.player,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    _snack(sent
        ? 'Sent again to ${partner.displayName}. It appears when they next open the app.'
        : "Couldn't send it. Check your connection and try again.");
  }

  Widget _countdownCard(ChastityTimerView view, ThemeData theme) {
    final String big;
    final String small;
    String? extra;
    if (view.status == TimerStatus.released) {
      big = 'Unlocked';
      small = view.endedByPlayerChoice
          ? (view.role == TimerRole.player ? 'You ended it' : 'Ended by your player')
          : view.releasedBy == TimerRole.player
              ? 'Ended by emergency release'
              : 'Ended by the director';
      extra = 'Ran for ${formatSpan(view.elapsed)}';
    } else if (view.isOver) {
      big = 'Unlocked';
      small = 'The timer has finished';
      extra = 'Ran for ${formatSpan(view.elapsed)}';
    } else if (view.config.openEnded) {
      // No end time: it counts up.
      big = formatCountdown(view.elapsed);
      small = 'locked so far · no end time';
      if (view.config.maxTotalSeconds != null) {
        extra = 'Ends by itself after ${formatSpan(Duration(seconds: view.config.maxTotalSeconds!))}';
      }
    } else if (view.remaining == null) {
      big = '??:??:??';
      small = 'The time left is hidden';
      extra = 'Locked for ${formatSpan(view.elapsed)} so far';
    } else {
      big = formatCountdown(view.remaining!);
      small = 'left';
      extra = 'Locked for ${formatSpan(view.elapsed)} so far';
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
        child: Column(
          children: [
            Icon(view.isOver ? Icons.lock_open_rounded : Icons.lock_rounded,
                size: 36,
                color:
                    view.isOver ? Colors.greenAccent[400] : Colors.pinkAccent),
            const SizedBox(height: 10),
            FittedBox(
              child: Text(
                big,
                style: const TextStyle(
                    fontSize: 44,
                    fontWeight: FontWeight.w800,
                    fontFeatures: [FontFeature.tabularFigures()]),
              ),
            ),
            Text(small,
                style: TextStyle(
                    color:
                        theme.colorScheme.onSurface.withValues(alpha: 0.65))),
            if (extra != null) ...[
              const SizedBox(height: 4),
              Text(extra,
                  style: TextStyle(
                      fontSize: 13,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
            ],
            if (view.config.maxTotalSeconds != null &&
                !view.isOver &&
                !view.config.openEnded &&
                view.remaining != null) ...[
              const SizedBox(height: 6),
              Text(
                  'Can never run past ${formatSpan(Duration(seconds: view.config.maxTotalSeconds!))} in total',
                  style: TextStyle(
                      fontSize: 12,
                      color:
                          theme.colorScheme.onSurface.withValues(alpha: 0.5))),
            ],
          ],
        ),
      ),
    );
  }

  Widget _actionsCard(ChastityTimerView view, ThemeData theme) {
    final isDirector = view.role == TimerRole.director;
    final open = view.config.openEnded;
    final canAdd = !open &&
        (isDirector ? view.config.director.canAdd : true) && !view.atMaximum;
    final canRemove = !open && isDirector && view.config.director.canRemove;
    Widget quick(Duration d, {required bool add}) => ActionChip(
          label: Text('${add ? '+' : '−'}${formatSpan(d)}'),
          onPressed: _busy ? null : () => _change(view, add: add, amount: d),
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (view.atMaximum) ...[
              Text(
                'This timer is at its maximum length. No more time can be added.',
                style: TextStyle(
                    fontSize: 13,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.75)),
              ),
              const SizedBox(height: 12),
            ],
            if (canAdd) ...[
              Text('ADD TIME', style: _label(theme)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                quick(const Duration(minutes: 15), add: true),
                quick(const Duration(hours: 1), add: true),
                quick(const Duration(days: 1), add: true),
                ActionChip(
                    label: const Text('Other…'),
                    onPressed: _busy ? null : () => _change(view, add: true)),
              ]),
            ],
            if (canRemove) ...[
              const SizedBox(height: 14),
              Text('REMOVE TIME', style: _label(theme)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                quick(const Duration(minutes: 15), add: false),
                quick(const Duration(hours: 1), add: false),
                quick(const Duration(days: 1), add: false),
                ActionChip(
                    label: const Text('Other…'),
                    onPressed: _busy ? null : () => _change(view, add: false)),
              ]),
            ],
            if (isDirector && !open && view.config.director.dailyCapSeconds != null) ...[
              const SizedBox(height: 10),
              Text(
                  'Limit: ${formatSpan(Duration(seconds: view.config.director.dailyCapSeconds!))} of changes per 24 hours.',
                  style: TextStyle(
                      fontSize: 12,
                      color:
                          theme.colorScheme.onSurface.withValues(alpha: 0.6))),
            ],
            const SizedBox(height: 16),
            if (view.playerMayEnd && !isDirector)
              FilledButton.tonalIcon(
                onPressed: _busy ? null : () => _release(view),
                icon: const Icon(Icons.lock_open_rounded),
                label: const Text('End timer'),
              )
            else
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _release(view),
                icon: const Icon(Icons.lock_open_rounded, color: Colors.redAccent),
                label: Text(isDirector ? 'End the timer now' : 'Emergency release',
                    style: const TextStyle(color: Colors.redAccent)),
                style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.redAccent)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _combinationCard(ChastityTimerView view, ThemeData theme) {
    final digits = view.config.combinationDigits;
    return Card(
      child: ListTile(
        leading: const Icon(Icons.pin_rounded),
        title: Text(digits == null ? 'Combination' : digits.split('').join(' '),
            style: TextStyle(
              fontSize: digits == null ? 16 : 26,
              fontWeight: FontWeight.bold,
              letterSpacing: digits == null ? 0 : 4,
              fontFeatures: const [FontFeature.tabularFigures()],
            )),
        subtitle: Text(digits == null
            ? 'Revealed when the timer ends (${view.config.combinationLength ?? '?'} digits).'
            : view.role == TimerRole.director && !view.isOver
                ? 'The player sees this only when the timer ends.'
                : 'Your combination.'),
      ),
    );
  }

  Widget _publicCard(ChastityTimerView view, ThemeData theme) {
    final link = view.publicId == null
        ? null
        : ChastityTimerService.publicLinkFor(view.publicId!);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text('PUBLIC LINK', style: _label(theme))),
                if (view.isManager && !view.isOver)
                  Switch(
                    value: view.config.publicLink.enabled,
                    onChanged: _busy ? null : (on) => _togglePublic(view, on),
                  ),
              ],
            ),
            if (!view.isManager && link == null)
              Text(!view.config.publicLink.enabled
                  ? 'No public link.'
                  : view.config.openEnded
                      ? "Anyone with the link can see how long it's been running."
                      : 'Anyone with the link can ${view.config.publicLink.allowRemove ? 'add or remove' : 'add'} time.')
            else if (link == null)
              Text(view.config.openEnded
                  ? "Off. Switch it on to show anyone with the link how long it's been running."
                  : 'Off. Switch it on to let anyone with the link vote.')
            else ...[
              SelectableText(link,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                'Each vote: ${formatSpan(Duration(seconds: view.config.publicLink.stepSeconds))}'
                '${view.config.publicLink.allowRemove ? ', either way' : ', adding only'}. '
                'Per visitor: ${formatSpan(Duration(seconds: view.config.publicLink.perVisitorDailySeconds))} a day.',
                style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.65)),
              ),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
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
                  onPressed: () => launchUrl(Uri.parse(link),
                      mode: LaunchMode.externalApplication),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.code_rounded, size: 18),
                  label: const Text('Embed'),
                  onPressed: () => _showEmbedSheet(link),
                ),
                if (view.isManager)
                  TextButton.icon(
                    icon: const Icon(Icons.autorenew_rounded, size: 18),
                    label: const Text('New link'),
                    onPressed: _busy
                        ? null
                        : () => _run(() => _timers.replaceLink(widget.timerId),
                            done:
                                'New link made. The old one no longer works.'),
                  ),
              ]),
              // Only a director manages a player's timer; the player-managed
              // timer is the player's own, with the link already theirs.
              if (view.isManager &&
                  view.role == TimerRole.director &&
                  !view.isOver)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: view.config.publicLink.shareWithPlayer,
                  onChanged: _busy
                      ? null
                      : (on) => _run(
                            () => _timers.configure(widget.timerId, {
                              'public': {
                                ...view.config.publicLink.toJson(),
                                'shareWithPlayer': on
                              },
                            }),
                            done: on
                                ? 'Your player can now see and share the link.'
                                : 'The link is no longer shown to your player.',
                            partnerSummary: on
                                ? 'Your director gave you the link to your timer.'
                                : null,
                          ),
                  title: const Text('Give your player the link too'),
                  subtitle: const Text(
                      'So they can hand it out. Only you can replace it or switch it off.'),
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// Snippets for putting this public timer on other people's pages: a live
  /// widget for websites, and an image for forums, which mostly allow images
  /// but not frames. Both say "Timer ended" once it is gone.
  void _showEmbedSheet(String link) {
    final snippets = <(String, String, String)>[
      (
        'Website or blog',
        'A live countdown with a Vote button.',
        '<iframe src="$link/embed" width="340" height="150" style="border:0;max-width:100%" title="Chastity Timer"></iframe>',
      ),
      (
        'Forum (BBCode)',
        'For forums that use [img] tags. Shows the time left when the post is loaded.',
        '[url=$link][img]$link/badge.svg[/img][/url]',
      ),
      (
        "Forum, if the image above doesn't show",
        "Some forums don't accept that kind of image. This one always works, but shows the status, not the time.",
        '[url=$link][img]$link/badge.png[/img][/url]',
      ),
      (
        'Markdown',
        'For sites that use Markdown, like many forums and READMEs.',
        '[![Chastity Timer]($link/badge.svg)]($link)',
      ),
      (
        'Website, as an image',
        "For pages that don't allow embeds.",
        '<a href="$link"><img src="$link/badge.svg" alt="Chastity Timer" width="320" height="64"></a>',
      ),
    ];
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              const Text('Embed this timer', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(
                'Copy one of these into a post or page. If you make a new link, '
                'embeds of this one will show "Timer ended".',
                style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurface.withValues(alpha: 0.7)),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.forum_rounded, size: 18),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Discord, Slack, iMessage and most chat apps: just paste the link. '
                        'It shows a preview card with the time left.',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              for (final (title, about, code) in snippets)
                Card(
                  margin: const EdgeInsets.only(top: 10),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 6, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold))),
                            TextButton.icon(
                              icon: const Icon(Icons.copy_rounded, size: 16),
                              label: const Text('Copy'),
                              onPressed: () {
                                Clipboard.setData(ClipboardData(text: code));
                                Navigator.pop(ctx);
                                _snack('$title code copied.');
                              },
                            ),
                          ],
                        ),
                        Text(about, style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withValues(alpha: 0.65))),
                        const SizedBox(height: 6),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(8),
                          margin: const EdgeInsets.only(right: 8),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: SelectableText(code, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _historyCard(
      ChastityTimerView view, TimerRecord record, ThemeData theme) {
    final entries = view.history.reversed.toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('HISTORY', style: _label(theme)),
            const SizedBox(height: 8),
            // A hidden timer does not tell the player how long it started at.
            Text(
                view.config.openEnded
                    ? 'Started ${_when(view.startAt)}, with no end time.'
                    : view.config.baseSeconds > 0
                    ? 'Started ${_when(view.startAt)}, at ${formatSpan(Duration(seconds: view.config.baseSeconds))}.'
                    : 'Started ${_when(view.startAt)}.',
                style: TextStyle(
                    fontSize: 13,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.7))),
            if (entries.isEmpty)
              const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('No changes yet.')),
            ...entries.take(100).map((e) => ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(_actorIcon(e.actor), size: 20),
                  title: Text(actorLabel(e.actor,
                      partnerName: record.partnerName, viewer: view.role)),
                  subtitle: Text(_when(e.at)),
                  trailing: Text(
                    e.deltaSeconds == null
                        ? 'changed'
                        : formatChange(e.deltaSeconds!),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: e.deltaSeconds == null
                          ? null
                          : e.deltaSeconds! >= 0
                              ? Colors.pinkAccent
                              : Colors.greenAccent[400],
                    ),
                  ),
                )),
          ],
        ),
      ),
    );
  }

  IconData _actorIcon(TimerActor a) => switch (a) {
        TimerActor.player => Icons.person_rounded,
        TimerActor.director => Icons.admin_panel_settings_rounded,
        TimerActor.random => Icons.casino_rounded,
        TimerActor.public => Icons.public_rounded,
      };

  String _when(DateTime t) {
    final local = t.toLocal();
    final diff = DateTime.now().difference(local);
    String two(int n) => n.toString().padLeft(2, '0');
    final clock = '${two(local.hour)}:${two(local.minute)}';
    if (diff.inDays == 0 && local.day == DateTime.now().day) {
      return 'today at $clock';
    }
    if (diff.inDays < 7) {
      return '${diff.inDays == 0 ? 1 : diff.inDays}d ago at $clock';
    }
    return '${local.day}/${local.month} at $clock';
  }

  TextStyle _label(ThemeData theme) => TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.bold,
      letterSpacing: 1.2,
      color: theme.colorScheme.primary);
}
