import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/public_visitor_service.dart';

/// "2d 04:15:09": a live countdown.
String _clock(Duration d) {
  final s = d.isNegative ? 0 : d.inSeconds;
  String two(int n) => n.toString().padLeft(2, '0');
  final clock = '${two(s % 86400 ~/ 3600)}:${two(s % 3600 ~/ 60)}:${two(s % 60)}';
  return s >= 86400 ? '${s ~/ 86400}d $clock' : clock;
}

/// "3 days 4 hours", "45 minutes".
String _span(Duration d) {
  final total = d.inMinutes.abs();
  if (total == 0) return '${d.inSeconds.abs()} seconds';
  final days = total ~/ 1440, hours = total % 1440 ~/ 60, minutes = total % 60;
  return [
    if (days > 0) '$days ${days == 1 ? 'day' : 'days'}',
    if (hours > 0) '$hours ${hours == 1 ? 'hour' : 'hours'}',
    if (minutes > 0) '$minutes ${minutes == 1 ? 'minute' : 'minutes'}',
  ].join(' ');
}

/// Someone else's public timer - or player page - in the app: the countdown,
/// voting, sending orders, and the proof for this app's own orders.
class PublicTimerView extends StatefulWidget {
  const PublicTimerView({super.key, required this.kind, required this.id});

  /// 't' for a timer's link, 'p' for a player's page.
  final String kind;
  final String id;

  @override
  State<PublicTimerView> createState() => _PublicTimerViewState();
}

class _PublicTimerViewState extends State<PublicTimerView> with WidgetsBindingObserver {
  PublicPage? _page;
  bool _loading = true;
  bool _busy = false;
  Duration _offset = Duration.zero;
  Timer? _tick;
  Timer? _poll;

  PublicVisitorService get _visitor => Provider.of<PublicVisitorService>(context, listen: false);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => mounted ? setState(() {}) : null);
    _poll = Timer.periodic(const Duration(seconds: 30), (_) => _load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tick?.cancel();
    _poll?.cancel();
    super.dispose();
  }

  /// Back from the browser's check: see whether it passed.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_visitor.isVerified) _visitor.checkVerified();
  }

  Future<void> _load() async {
    final page = await _visitor.fetch(widget.kind, widget.id);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (page != null) {
        _page = page;
        final now = page.state['now'];
        if (now is num) _offset = DateTime.fromMillisecondsSinceEpoch(now.toInt()).difference(DateTime.now());
      }
    });
  }

  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text), behavior: SnackBarBehavior.floating));

  static const _reasons = {
    'visitor-cap': "You've used today's allowance here. Come back tomorrow.",
    'daily-cap': "Today's limit for this timer has been reached.",
    'not-running': 'This timer has finished.',
    'not-allowed': "That isn't allowed on this timer.",
    'at-maximum': 'This timer is already at its maximum length.',
    'paused': "They've just skipped one, so orders are paused for a little while.",
    'full': 'Their order queue is full right now.',
    'orders-off': "This timer isn't taking orders.",
    'unknown-order': "That order isn't on the list any more.",
    'slow-down': 'Too many tries just now. Wait a minute, then try again.',
  };

  /// Runs a vote or order; the first time, it may need the one-time check.
  Future<void> _act(Future<String?> Function() action, String done) async {
    setState(() => _busy = true);
    final error = await action();
    if (!mounted) return;
    setState(() => _busy = false);
    if (error == 'verify') {
      await _askToVerify();
      return;
    }
    _snack(error == null ? done : (_reasons[error] ?? "That didn't go through. Check your connection."));
    _load();
  }

  Future<void> _askToVerify() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('A one-time check'),
        content: const Text(
          'To vote and send orders from the app, show you are a person once - a quick check in your '
          'browser. It brings you back here, and the app will not ask again.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not now')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Open the check')),
        ],
      ),
    );
    if (go != true || !mounted) return;
    final error = await _visitor.startVerification();
    if (error != null && mounted) _snack("Couldn't start the check. Try again in a moment.");
  }

  @override
  Widget build(BuildContext context) {
    final visitor = Provider.of<PublicVisitorService>(context);
    final page = _page;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(page?.name != null ? "${page!.name}'s timer" : 'Chastity Timer'),
        actions: [
          if (page != null)
            IconButton(
              tooltip: visitor.isWatching(widget.kind, widget.id) ? 'Stop watching' : 'Watch',
              icon: Icon(visitor.isWatching(widget.kind, widget.id)
                  ? Icons.notifications_active_rounded
                  : Icons.notifications_none_rounded),
              onPressed: () async {
                final on = !visitor.isWatching(widget.kind, widget.id);
                await visitor.watch(page, on: on);
                if (!mounted) return;
                _snack(on
                    ? (visitor.isVerified
                        ? "Watching. You'll be told when it ends."
                        : 'Added to Watching. Vote or order once to be told when it ends.')
                    : 'No longer watching.');
              },
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : page == null
              ? const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('This link no longer works.')))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: EdgeInsets.fromLTRB(16, 12, 16, 24 + MediaQuery.paddingOf(context).bottom),
                    children: [_timerCard(page, theme), ..._ordersSection(page, visitor, theme)],
                  ),
                ),
    );
  }

  Widget _timerCard(PublicPage page, ThemeData theme) {
    final t = page.timer;
    final now = DateTime.now().add(_offset);
    String big, small;
    String? extra;
    if (t == null) {
      big = 'Unlocked';
      small = '${page.name ?? 'They'} ${page.name == null ? "aren't" : "isn't"} locked up right now';
    } else {
      DateTime? at(String k) => t[k] is num ? DateTime.fromMillisecondsSinceEpoch((t[k] as num).toInt()) : null;
      final start = at('startAt') ?? now;
      final end = at('endAt');
      if (t['status'] != 'running') {
        big = 'Unlocked';
        small = 'This timer is over';
        final closed = at('closedAt');
        if (closed != null) extra = 'Ran for ${_span(closed.difference(start))}';
      } else if (t['openEnded'] == true) {
        big = _clock(now.difference(start));
        small = 'locked so far · no end time';
      } else if (end == null) {
        big = '??:??:??';
        small = 'The time left is hidden';
        extra = 'Locked for ${_span(now.difference(start))} so far';
      } else {
        big = _clock(end.difference(now));
        small = 'left on the timer';
        extra = 'Locked for ${_span(now.difference(start))} so far';
      }
    }
    final canVote = t != null && t['acceptingVotes'] == true && t['openEnded'] != true;
    final step = Duration(seconds: (t?['stepSeconds'] as num?)?.toInt() ?? 600);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(children: [
          Text(big,
              style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w800, fontFeatures: [FontFeature.tabularFigures()])),
          Text(small, style: TextStyle(color: theme.colorScheme.onSurface.withValues(alpha: 0.65))),
          if (extra != null) Text(extra, style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
          if (canVote) ...[
            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: Colors.pinkAccent, foregroundColor: Colors.black),
                  onPressed: _busy || t['atMaximum'] == true
                      ? null
                      : () => _act(() => _visitor.vote(page.timerId!, 1), 'Time added. Thanks for voting.'),
                  child: Text('Add ${_span(step)}'),
                ),
              ),
              if (t['allowRemove'] == true) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: Colors.greenAccent, foregroundColor: Colors.black),
                    onPressed: _busy ? null : () => _act(() => _visitor.vote(page.timerId!, -1), 'Time removed. Thanks for voting.'),
                    child: Text('Remove ${_span(step)}'),
                  ),
                ),
              ],
            ]),
          ],
        ]),
      ),
    );
  }

  static const _status = {
    'queued': 'waiting',
    'active': 'in progress',
    'reviewing': 'being checked',
    'completed': 'done ✓',
    'failed': 'failed',
    'expired': 'ran out of time',
    'skipped': 'skipped',
    'cancelled': 'cancelled',
  };

  List<Widget> _ordersSection(PublicPage page, PublicVisitorService visitor, ThemeData theme) {
    final orders = page.orders;
    final timerId = page.timerId;
    if (orders == null || timerId == null) return const [];
    final toSender = orders['proofTo'] == 'issuer';
    final list = ((orders['list'] as List?) ?? const []).whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
    final feed = ((orders['feed'] as List?) ?? const []).whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
    final muted = TextStyle(fontSize: 13, color: theme.colorScheme.onSurface.withValues(alpha: 0.65));
    return [
      const SizedBox(height: 16),
      Text('SEND AN ORDER', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: theme.colorScheme.primary)),
      const SizedBox(height: 4),
      Text(
        orders['accepting'] == true
            ? (toSender
                ? 'They carry it out in their app. If it needs a photo, it comes to you here, to approve or reject.'
                : 'They carry it out in their app. Photo proof goes to whoever manages the timer.')
            : (_reasons[orders['reason']] ?? 'Not taking orders right now.'),
        style: muted,
      ),
      if (orders['accepting'] == true)
        for (final def in list)
          Card(
            child: ListTile(
              title: Text(def['title'] as String? ?? ''),
              subtitle: Text([
                if ((def['description'] as String? ?? '').isNotEmpty) def['description'] as String,
                if (def['verification'] == 'photoProof') 'photo proof',
                if ((def['rewardTokens'] as num? ?? 0) > 0) '+${def['rewardTokens']} tokens',
              ].join(' · ')),
              trailing: FilledButton(
                onPressed: _busy
                    ? null
                    : () => _act(() => _visitor.sendOrder(timerId, def, proofToSender: toSender),
                        'Order sent. Watch for it below.'),
                child: const Text('Send'),
              ),
            ),
          ),
      const SizedBox(height: 16),
      Text('ORDERS SO FAR', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: theme.colorScheme.primary)),
      if (feed.isEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text('None yet.', style: muted)),
      for (final f in feed)
        Builder(builder: (context) {
          final mine = visitor.sentOrder(timerId, (f['no'] as num).toInt());
          final status = f['status'] as String? ?? '';
          final label = status == 'completed' && f['auto'] == true ? 'done ✓ (not checked)' : (_status[status] ?? status);
          return ListTile(
            contentPadding: EdgeInsets.zero,
            title: Row(children: [
              Flexible(child: Text(f['title'] as String? ?? '', overflow: TextOverflow.ellipsis)),
              if (mine != null)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Text('YOURS',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: theme.colorScheme.primary)),
                ),
            ]),
            trailing: mine != null && f['hasProof'] == true
                ? FilledButton.tonal(
                    onPressed: () => _showProof(mine, reviewing: status == 'reviewing'),
                    child: Text(status == 'reviewing' ? 'Check proof' : 'See proof'),
                  )
                : Text(label, style: muted),
          );
        }),
    ];
  }

  Future<void> _showProof(SentOrder order, {required bool reviewing}) async {
    final proof = await _visitor.proof(order);
    if (!mounted) return;
    if (proof == null) {
      _snack('This proof is no longer available, or this app cannot open it.');
      return;
    }
    final isImage = proof.mime.startsWith('image/');
    final verdict = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(order.title),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (isImage)
              ClipRRect(borderRadius: BorderRadius.circular(10), child: Image.memory(proof.bytes, fit: BoxFit.contain))
            else
              Text(utf8.decode(proof.bytes, allowMalformed: true)),
            if (reviewing) ...[
              const SizedBox(height: 12),
              const Text('Does it show the order was done? If you leave it too long, it is approved.'),
            ],
          ]),
        ),
        actions: reviewing
            ? [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Later')),
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Reject')),
                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Approve')),
              ]
            : [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ),
    );
    if (verdict == null || !mounted) return;
    final error = await _visitor.review(order, approve: verdict);
    if (!mounted) return;
    _snack(error == null
        ? (verdict ? 'Approved. They get the tokens for it.' : 'Rejected. It counts as failed.')
        : 'Too late to decide - it has already been settled.');
    _load();
  }
}

/// The public pages this app is watching.
class WatchingView extends StatelessWidget {
  const WatchingView({super.key});

  @override
  Widget build(BuildContext context) {
    final visitor = Provider.of<PublicVisitorService>(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Watching')),
      body: visitor.watching.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  "Timers you watch show here. Open someone's public link and choose \"Open in the app\", "
                  'then tap the bell.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                for (final w in visitor.watching)
                  Card(
                    child: ListTile(
                      leading: Icon(w.kind == 'p' ? Icons.person_rounded : Icons.lock_clock_rounded),
                      title: Text(w.label ?? (w.kind == 'p' ? "Someone's page" : 'A public timer')),
                      subtitle: Text('subtaskmanager.com/${w.kind}/${w.id}'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => Navigator.of(context)
                          .push(MaterialPageRoute(builder: (_) => PublicTimerView(kind: w.kind, id: w.id))),
                    ),
                  ),
              ],
            ),
    );
  }
}
