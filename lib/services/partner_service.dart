import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/partner_contact.dart';

class IncomingPairingRequest {
  final String senderId;
  final String senderCode;
  final String senderName;
  final PartnerRole senderRole;
  final String sharedSecret;
  final DateTime timestamp;

  IncomingPairingRequest({
    required this.senderId,
    required this.senderCode,
    required this.senderName,
    required this.senderRole,
    required this.sharedSecret,
    required this.timestamp,
  });
}

class PartnerService extends ChangeNotifier {
  List<PartnerContact> _contacts = [];
  final List<IncomingPairingRequest> _pendingRequests = [];
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
    // Check if code or id already exists
    final idx = _contacts.indexWhere((c) => c.id == contact.id || (c.pairingCode.isNotEmpty && c.pairingCode == contact.pairingCode));
    if (idx >= 0) {
      _contacts[idx] = contact;
    } else {
      _contacts.add(contact);
    }

    _activePartnerId ??= contact.id;
    _pendingRequests.removeWhere((r) =>
        r.senderId == contact.id ||
        (contact.pairingCode.isNotEmpty && r.senderCode.toUpperCase() == contact.pairingCode.toUpperCase()));
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

  /// Automatically updates an existing contact's pairing code & secret upon receiving an identity migration beacon.
  Future<bool> updateContactPairingIdentity({
    String? deviceId,
    String? oldCode,
    required String newCode,
    String? newSecret,
    String? newDisplayName,
  }) async {
    int idx = -1;
    if (oldCode != null && oldCode.trim().isNotEmpty) {
      idx = _contacts.indexWhere((c) => c.pairingCode.toUpperCase() == oldCode.trim().toUpperCase());
    }
    if (idx < 0 && deviceId != null && deviceId.trim().isNotEmpty) {
      idx = _contacts.indexWhere((c) => c.id == deviceId.trim());
    }

    if (idx >= 0) {
      final current = _contacts[idx];
      _contacts[idx] = current.copyWith(
        pairingCode: newCode.trim().toUpperCase(),
        pairingSecret: (newSecret != null && newSecret.trim().isNotEmpty) ? newSecret.trim() : current.pairingSecret,
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
    if (code.isEmpty) return null;
    final match = _contacts.where((c) => c.pairingCode.toLowerCase() == code.toLowerCase());
    return match.isNotEmpty ? match.first : null;
  }

  PartnerContact? findContactById(String id) {
    if (id.isEmpty) return null;
    if (id == PartnerContact.selfId) return PartnerContact.self();
    final match = _contacts.where((c) => c.id == id);
    return match.isNotEmpty ? match.first : null;
  }

  bool isSenderBlocked(String senderIdOrCode) {
    for (final c in _contacts) {
      if ((c.id == senderIdOrCode || (c.pairingCode.isNotEmpty && c.pairingCode == senderIdOrCode)) && c.isBlocked) {
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

  bool isExistingContactOrSelf(String? id, String? code, {String? ownCode, String? ownDeviceId}) {
    if (id != null && id.isNotEmpty) {
      if (id == PartnerContact.selfId || (ownDeviceId != null && ownDeviceId.isNotEmpty && id == ownDeviceId)) {
        return true;
      }
      if (findContactById(id) != null) return true;
    }
    if (code != null && code.isNotEmpty) {
      if (ownCode != null && ownCode.isNotEmpty && code.toUpperCase() == ownCode.toUpperCase()) {
        return true;
      }
      if (findContactByCode(code) != null) return true;
    }
    return false;
  }

  void cleanExistingContactRequests({String? ownCode, String? ownDeviceId}) {
    final beforeCount = _pendingRequests.length;
    _pendingRequests.removeWhere((r) => isExistingContactOrSelf(r.senderId, r.senderCode, ownCode: ownCode, ownDeviceId: ownDeviceId));
    if (_pendingRequests.length != beforeCount) {
      notifyListeners();
    }
  }

  void addIncomingRequest(IncomingPairingRequest req, {String? ownCode, String? ownDeviceId}) {
    if (isSenderBlocked(req.senderId) || isSenderBlocked(req.senderCode)) return;
    if (isExistingContactOrSelf(req.senderId, req.senderCode, ownCode: ownCode, ownDeviceId: ownDeviceId)) return;
    _pendingRequests.removeWhere((r) => r.senderId == req.senderId || r.senderCode == req.senderCode);
    _pendingRequests.add(req);
    notifyListeners();
  }

  void removeIncomingRequest(String senderIdOrCode) {
    _pendingRequests.removeWhere((r) => r.senderId == senderIdOrCode || r.senderCode.toUpperCase() == senderIdOrCode.toUpperCase());
    notifyListeners();
  }
}
