import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';

class SecurityService extends ChangeNotifier {
  static const String _pinHashKey = 'app_pin_hash';
  static const String _pinEnabledKey = 'app_pin_enabled';

  bool _isPinRequired = false;
  bool _isUnlocked = false;
  bool _isPanicModeActive = false;
  String? _storedPinHash;
  int _storedPinLength = 4;

  bool get isPinRequired => _isPinRequired;
  bool get isUnlocked => _isUnlocked;
  bool get isPanicModeActive => _isPanicModeActive;
  int get pinLength => _storedPinLength;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _isPinRequired = prefs.getBool(_pinEnabledKey) ?? false;
    _storedPinHash = prefs.getString(_pinHashKey);
    _storedPinLength = prefs.getInt('app_pin_length') ?? 4;
    _isUnlocked = !_isPinRequired;
    notifyListeners();
  }

  Future<bool> verifyPin(String enteredPin) async {
    return verifyPinSync(enteredPin);
  }

  bool verifyPinSync(String enteredPin) {
    if (_storedPinHash == null) {
      _isUnlocked = true;
      notifyListeners();
      return true;
    }
    final enteredHash = sha256.convert(utf8.encode(enteredPin)).toString();
    if (enteredHash == _storedPinHash) {
      _isUnlocked = true;
      notifyListeners();
      return true;
    }
    return false;
  }

  Future<void> setPin(String newPin) async {
    final prefs = await SharedPreferences.getInstance();
    if (newPin.isEmpty) {
      await prefs.remove(_pinHashKey);
      await prefs.remove('app_pin_length');
      await prefs.setBool(_pinEnabledKey, false);
      _storedPinHash = null;
      _storedPinLength = 4;
      _isPinRequired = false;
      _isUnlocked = true;
    } else {
      final hash = sha256.convert(utf8.encode(newPin)).toString();
      await prefs.setString(_pinHashKey, hash);
      await prefs.setInt('app_pin_length', newPin.length);
      await prefs.setBool(_pinEnabledKey, true);
      _storedPinHash = hash;
      _storedPinLength = newPin.length;
      _isPinRequired = true;
    }
    notifyListeners();
  }

  void lockApp() {
    if (_isPinRequired) {
      _isUnlocked = false;
      notifyListeners();
    }
  }

  void triggerPanic() {
    _isPanicModeActive = true;
    notifyListeners();
  }

  void exitPanic() {
    _isPanicModeActive = false;
    notifyListeners();
  }
}
