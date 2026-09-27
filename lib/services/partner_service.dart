import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/partner_contact.dart';

class IncomingPairingRequest {
  final String senderId;
  final String senderCode;
  final String senderName;
  final PartnerRole senderRole;

  /// Identifies this one exchange: the requester's key commitment, or for a
  /// request from an older build, the secret it sent in the clear.
  final String exchangeId;

  /// From a build that sends the secret in the clear. Shown so the user knows
  /// to ask their partner to update, but it cannot be accepted.
  final bool isLegacy;

  /// From someone who is already a contact, asking to replace the secret the
  /// two of you share.
  final bool isRepair;

  final DateTime timestamp;

  IncomingPairingRequest({
    required this.senderId,
    required this.senderCode,
    required this.senderName,
    required this.senderRole,
    required this.exchangeId,
    required this.timestamp,
    this.isLegacy = false,
    this.isRepair = false,
  });
}

/// This device's half of a private pairing exchange that has not finished.
///
/// The private key never leaves the device; it is kept only until the other
/// side's key arrives, and dropped as soon as the secret is worked out.
class PendingPairingExchange {
  /// The requester's key commitment, which both sides use to name the
  /// exchange.
  final String commitment;
  final bool isRequester;
  final String peerCode;
  final BigInt privateKey;
  final String publicKey;
  final DateTime createdAt;

  PendingPairingExchange({
    required this.commitment,
    required this.isRequester,
    required this.peerCode,
    required this.privateKey,
    required this.publicKey,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'commitment': commitment,
        'isRequester': isRequester,
        'peerCode': peerCode,
        'privateKey': privateKey.toRadixString(16),
        'publicKey': publicKey,
        'createdAt': createdAt.millisecondsSinceEpoch,
      };

  factory PendingPairingExchange.fromJson(Map<String, dynamic> json) =>
      PendingPairingExchange(
        commitment: json['commitment'] as String,
        isRequester: json['isRequester'] as bool,
        peerCode: json['peerCode'] as String,
        privateKey: BigInt.parse(json['privateKey'] as String, radix: 16),
        publicKey: json['publicKey'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (json['createdAt'] as num).toInt()),
      );
}

class PartnerService extends ChangeNotifier {
  static String normalizeCode(String? code) {
    if (code == null) return '';
    return code.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  }

  List<PartnerContact> _contacts = [];
  final List<IncomingPairingRequest> _pendingRequests = [];
  final List<PendingPairingExchange> _pendingExchanges = [];

  static const _pendingExchangesKey = 'pending_pairing_exchanges_v1';

  /// How long a half-finished exchange is kept waiting for the other side.
  static const pendingExchangeLifetime = Duration(days: 14);
  final Set<String> _handledRequestFingerprints = {};
  String? _activePartnerId;
  bool _initialized = false;

  List<PartnerContact> get contacts => List.unmodifiable(_contacts);
  List<IncomingPairingRequest> get pendingRequests => List.unmodifiable(_pendingRequests);
  List<PartnerContact> get unblockedContacts =>
      _contacts.where((c) => !c.isBlocked).toList();
  List<PartnerContact> get blockedContacts =>
      _contacts.where((c) => c.isBlocked).toList();

  String? get activePartnerId => _activePartnerId ?? (_contacts.isNotEmpty ? _contacts.first.id : PartnerContact.selfId);
  PartnerContact? get activePartner {
    final effectiveId = _activePartnerId ?? (_contacts.isNotEmpty ? _contacts.first.id : PartnerContact.selfId);
    if (effectiveId == PartnerContact.selfId) {
      return PartnerContact.self();
    }
    return _contacts.firstWhere(
      (c) => c.id == effectiveId,
      orElse: () => _contacts.isNotEmpty ? _contacts.first : PartnerContact.self(),
    );
  }

  int get totalUnreadCount {
    int sum = 0;
    for (final c in _contacts) {
      if (!c.isBlocked) sum += c.unreadCount;
    }
    return sum;
  }

  int unreadCount(String partnerId) {
    if (partnerId == PartnerContact.selfId) return 0;
    return findContactById(partnerId)?.unreadCount ?? 0;
  }

  Future<void> init() async {
    if (_initialized) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedJson = prefs.getString('partner_contacts_list');
      if (savedJson != null && savedJson.isNotEmpty) {
        final List<dynamic> decoded = jsonDecode(savedJson);
        _contacts = decoded.map((e) => PartnerContact.fromJson(e as Map<String, dynamic>)).toList();
      }

      final savedFingerprints = prefs.getStringList('handled_pairing_request_fingerprints_v1');
      if (savedFingerprints != null) {
        _handledRequestFingerprints.addAll(savedFingerprints);
      }

      final cutoff = DateTime.now().subtract(pendingExchangeLifetime);
      for (final raw in prefs.getStringList(_pendingExchangesKey) ?? const <String>[]) {
        try {
          final e = PendingPairingExchange.fromJson(jsonDecode(raw) as Map<String, dynamic>);
          if (e.createdAt.isAfter(cutoff)) _pendingExchanges.add(e);
        } catch (_) {}
      }

      // Automatically ensure all current contacts are registered in handled fingerprints
      for (final c in _contacts) {
        final clean = normalizeCode(c.pairingCode);
        if (clean.isNotEmpty) {
          _handledRequestFingerprints.add(clean);
          if (c.pairingSecret.isNotEmpty) {
            _handledRequestFingerprints.add('${clean}_${c.pairingSecret.trim()}');
          }
        }
      }

      _activePartnerId = prefs.getString('active_partner_id');
      if (_activePartnerId == null && _contacts.isNotEmpty) {
        _activePartnerId = _contacts.first.id;
      }
      cleanExistingContactRequests();
      _initialized = true;
      notifyListeners();
    } catch (e) {
      if (kDebugMode) print('Error initializing PartnerService: $e');
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode(_contacts.map((c) => c.toJson()).toList());
      await prefs.setString('partner_contacts_list', encoded);
      await prefs.setString('partner_contacts_v1', encoded);
      await prefs.setStringList('handled_pairing_request_fingerprints_v1', _handledRequestFingerprints.toList());
      if (_activePartnerId != null) {
        await prefs.setString('active_partner_id', _activePartnerId!);
      } else {
        await prefs.remove('active_partner_id');
      }
    } catch (e) {
      if (kDebugMode) print('Error saving PartnerService: $e');
    }
  }

  Future<void> addContact(PartnerContact contact) async {
    final clean = normalizeCode(contact.pairingCode);
    final idx = _contacts.indexWhere((c) =>
        c.id == contact.id ||
        (clean.isNotEmpty && normalizeCode(c.pairingCode) == clean));
    if (idx >= 0) {
      _contacts[idx] = contact;
    } else {
      _contacts.add(contact);
    }

    _activePartnerId ??= contact.id;
    if (clean.isNotEmpty) {
      _handledRequestFingerprints.add(clean);
      if (contact.pairingSecret.isNotEmpty) {
        _handledRequestFingerprints.add('${clean}_${contact.pairingSecret.trim()}');
      }
    }
    _pendingRequests.removeWhere((r) =>
        r.senderId == contact.id ||
        (clean.isNotEmpty && normalizeCode(r.senderCode) == clean));
    await _save();
    notifyListeners();
  }

  Future<void> updateContact(PartnerContact contact) async {
    final idx = _contacts.indexWhere((c) => c.id == contact.id);
    if (idx >= 0) {
      _contacts[idx] = contact;
      await _save();
      notifyListeners();
    }
  }

  int _indexForMigration({String? deviceId, String? oldCode}) {
    int idx = -1;
    if (oldCode != null && oldCode.trim().isNotEmpty) {
      idx = _contacts.indexWhere((c) => c.pairingCode.toUpperCase() == oldCode.trim().toUpperCase());
    }
    if (idx < 0 && deviceId != null && deviceId.trim().isNotEmpty) {
      idx = _contacts.indexWhere((c) => c.id == deviceId.trim());
    }
    return idx;
  }

  /// The contact an identity migration beacon is about.
  PartnerContact? findContactForMigration({String? deviceId, String? oldCode}) {
    final idx = _indexForMigration(deviceId: deviceId, oldCode: oldCode);
    return idx >= 0 ? _contacts[idx] : null;
  }

  /// Moves an existing contact to the new pairing code from an identity
  /// migration beacon. The key shared with them stays as it is: changing
  /// code is not changing key.
  Future<bool> updateContactPairingIdentity({
    String? deviceId,
    String? oldCode,
    required String newCode,
    String? newDisplayName,
  }) async {
    final idx = _indexForMigration(deviceId: deviceId, oldCode: oldCode);

    if (idx >= 0) {
      final current = _contacts[idx];
      _contacts[idx] = current.copyWith(
        pairingCode: newCode.trim().toUpperCase(),
        displayName: (newDisplayName != null && newDisplayName.trim().isNotEmpty) ? newDisplayName.trim() : current.displayName,
        lastSeen: DateTime.now(),
      );
      await _save();
      notifyListeners();
      return true;
    }
    return false;
  }

  Future<void> deleteContact(String contactId) async {
    _contacts.removeWhere((c) => c.id == contactId);
    if (_activePartnerId == contactId) {
      _activePartnerId = _contacts.isNotEmpty ? _contacts.first.id : null;
    }
    await _save();
    notifyListeners();
  }

  Future<void> toggleBlock(String contactId) async {
    final idx = _contacts.indexWhere((c) => c.id == contactId);
    if (idx >= 0) {
      final current = _contacts[idx];
      _contacts[idx] = current.copyWith(isBlocked: !current.isBlocked);
      await _save();
      notifyListeners();
    }
  }

  Future<void> setBlocked(String contactId, bool isBlocked) async {
    final idx = _contacts.indexWhere((c) => c.id == contactId);
    if (idx >= 0) {
      _contacts[idx] = _contacts[idx].copyWith(isBlocked: isBlocked);
      await _save();
      notifyListeners();
    }
  }

  Future<void> setActivePartner(String contactId) async {
    if (contactId == PartnerContact.selfId || _contacts.any((c) => c.id == contactId)) {
      _activePartnerId = contactId;
      await _save();
      notifyListeners();
    }
  }

  PartnerContact? findContactByCode(String code) {
    final clean = normalizeCode(code);
    if (clean.isEmpty) return null;
    final match = _contacts.where((c) => normalizeCode(c.pairingCode) == clean);
    return match.isNotEmpty ? match.first : null;
  }

  PartnerContact? findContactById(String id) {
    if (id.isEmpty) return null;
    if (id == PartnerContact.selfId) return PartnerContact.self();
    final match = _contacts.where((c) => c.id == id);
    return match.isNotEmpty ? match.first : null;
  }

  bool isSenderBlocked(String senderIdOrCode) {
    final cleanCode = normalizeCode(senderIdOrCode);
    for (final c in _contacts) {
      if ((c.id == senderIdOrCode || (cleanCode.isNotEmpty && normalizeCode(c.pairingCode) == cleanCode)) && c.isBlocked) {
        return true;
      }
    }
    return false;
  }

  Future<void> incrementUnread(String contactId) async {
    final idx = _contacts.indexWhere((c) => c.id == contactId);
    if (idx >= 0) {
      _contacts[idx] = _contacts[idx].copyWith(
        unreadCount: _contacts[idx].unreadCount + 1,
        lastSeen: DateTime.now(),
      );
      await _save();
      notifyListeners();
    }
  }

  Future<void> resetUnread(String contactId) async {
    final idx = _contacts.indexWhere((c) => c.id == contactId);
    if (idx >= 0 && _contacts[idx].unreadCount > 0) {
      _contacts[idx] = _contacts[idx].copyWith(unreadCount: 0);
      await _save();
      notifyListeners();
    }
  }

  Future<void> updateLastSeen(String contactId) async {
    final idx = _contacts.indexWhere((c) => c.id == contactId);
    if (idx >= 0) {
      _contacts[idx] = _contacts[idx].copyWith(lastSeen: DateTime.now());
      await _save();
      notifyListeners();
    }
  }

  /// Whether this exact pairing request has already been dealt with.
  ///
  /// Identity is the sender's code *plus the exchange id of that request*.
  /// A bare code is far too coarse: every request carries a fresh key
  /// commitment (or, from an older build, a fresh secret), so matching on the code alone meant that once someone's request
  /// had been handled even once - accepted, declined, or silently absorbed
  /// because they were already a contact - every future request from them was
  /// dropped without a trace, and they could never pair again.
  ///
  /// Permanently refusing a person is what blocking is for, and that is a
  /// separate, deliberate decision made through [isSenderBlocked].
  bool isRequestHandled(String? senderCode, [String? exchangeId]) {
    if (senderCode == null) return false;
    final clean = normalizeCode(senderCode);
    if (clean.isEmpty) return false;

    final secret = exchangeId?.trim() ?? '';
    if (secret.isNotEmpty) {
      return _handledRequestFingerprints.contains('${clean}_$secret');
    }
    // No secret to distinguish requests: fall back to the coarse match rather
    // than treating an unidentifiable repeat as new.
    return _handledRequestFingerprints.contains(clean);
  }

  Future<void> markRequestHandled(String senderCode, [String? exchangeId]) async {
    final clean = normalizeCode(senderCode);
    if (clean.isNotEmpty) {
      final secret = exchangeId?.trim() ?? '';
      if (secret.isNotEmpty) {
        // Only the specific exchange. Banking the bare code as well would
        // blacklist the sender forever, which is not what handling a request
        // means.
        _handledRequestFingerprints.add('${clean}_$secret');
      } else {
        _handledRequestFingerprints.add(clean);
      }
      _pendingRequests.removeWhere((r) => normalizeCode(r.senderCode) == clean);
      if (_handledRequestFingerprints.length > 500) {
        final toRemove = _handledRequestFingerprints.take(100).toList();
        _handledRequestFingerprints.removeAll(toRemove);
      }
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setStringList('handled_pairing_request_fingerprints_v1', _handledRequestFingerprints.toList());
      } catch (_) {}
      notifyListeners();
    }
  }

  bool isExistingContactOrSelf(String? id, String? code, {String? ownCode, String? ownDeviceId}) {
    if (id != null && id.trim().isNotEmpty) {
      final cleanId = id.trim();
      if (cleanId == PartnerContact.selfId || (ownDeviceId != null && ownDeviceId.trim().isNotEmpty && cleanId == ownDeviceId.trim())) {
        return true;
      }
      if (findContactById(cleanId) != null) return true;
    }
    if (code != null && code.trim().isNotEmpty) {
      final clean = normalizeCode(code);
      if (clean.isNotEmpty) {
        if (ownCode != null && normalizeCode(ownCode) == clean) {
          return true;
        }
        if (findContactByCode(clean) != null) return true;
      }
    }
    return false;
  }

  void cleanExistingContactRequests({String? ownCode, String? ownDeviceId}) {
    final beforeCount = _pendingRequests.length;
    _pendingRequests.removeWhere((r) =>
        !isRequestStillRelevant(r, ownCode: ownCode, ownDeviceId: ownDeviceId));
    if (_pendingRequests.length != beforeCount) {
      notifyListeners();
    }
  }

  /// A re-pair request is the one kind that should come from an existing
  /// contact, and it still never comes from this device itself.
  bool _isRepairFromContact(IncomingPairingRequest r, {String? ownCode, String? ownDeviceId}) {
    if (!r.isRepair) return false;
    final clean = normalizeCode(r.senderCode);
    if (clean.isEmpty || findContactByCode(clean) == null) return false;
    if (ownCode != null && normalizeCode(ownCode) == clean) return false;
    if (ownDeviceId != null && ownDeviceId.isNotEmpty && r.senderId == ownDeviceId) return false;
    return true;
  }

  /// Whether [req] should still be offered, given what has been handled and
  /// who is already a contact.
  bool isRequestStillRelevant(IncomingPairingRequest req, {String? ownCode, String? ownDeviceId}) {
    if (isRequestHandled(req.senderCode, req.exchangeId)) return false;
    if (_isRepairFromContact(req, ownCode: ownCode, ownDeviceId: ownDeviceId)) return true;
    return !isExistingContactOrSelf(req.senderId, req.senderCode, ownCode: ownCode, ownDeviceId: ownDeviceId);
  }

  void addIncomingRequest(IncomingPairingRequest req, {String? ownCode, String? ownDeviceId}) {
    if (isSenderBlocked(req.senderId) || isSenderBlocked(req.senderCode)) return;
    if (!isRequestStillRelevant(req, ownCode: ownCode, ownDeviceId: ownDeviceId)) return;

    _pendingRequests.removeWhere((r) =>
        r.senderId == req.senderId ||
        normalizeCode(r.senderCode) == normalizeCode(req.senderCode));
    _pendingRequests.add(req);
    notifyListeners();
  }

  void removeIncomingRequest(String senderIdOrCode) {
    final clean = normalizeCode(senderIdOrCode);
    _pendingRequests.removeWhere((r) =>
        r.senderId == senderIdOrCode ||
        (clean.isNotEmpty && normalizeCode(r.senderCode) == clean));
    notifyListeners();
  }

  /// Whether a private pairing with [code] has been started here and not yet
  /// finished.
  bool isPairingInProgress(String code) {
    final clean = normalizeCode(code);
    return clean.isNotEmpty &&
        _pendingExchanges.any((e) => normalizeCode(e.peerCode) == clean);
  }

  PendingPairingExchange? findPendingExchange(String commitment, {required bool asRequester}) {
    for (final e in _pendingExchanges) {
      if (e.commitment == commitment && e.isRequester == asRequester) return e;
    }
    return null;
  }

  Future<void> addPendingExchange(PendingPairingExchange exchange) async {
    _pendingExchanges.removeWhere((e) =>
        e.commitment == exchange.commitment && e.isRequester == exchange.isRequester);
    _pendingExchanges.add(exchange);
    await _savePendingExchanges();
    notifyListeners();
  }

  /// Drops every unfinished exchange with [peerCode]. Called once one of them
  /// completes, so a late answer to an older attempt cannot replace the
  /// secret that was just agreed.
  Future<void> clearPendingExchanges(String peerCode) async {
    final clean = normalizeCode(peerCode);
    _pendingExchanges.removeWhere((e) => normalizeCode(e.peerCode) == clean);
    await _savePendingExchanges();
    notifyListeners();
  }

  Future<void> _savePendingExchanges() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_pendingExchangesKey,
          _pendingExchanges.map((e) => jsonEncode(e.toJson())).toList());
    } catch (_) {}
  }
}
