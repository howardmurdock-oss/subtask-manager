import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../core/security/security_service.dart';

class PinLockScreen extends StatefulWidget {
  const PinLockScreen({super.key});

  @override
  State<PinLockScreen> createState() => _PinLockScreenState();
}

class _PinLockScreenState extends State<PinLockScreen> with SingleTickerProviderStateMixin {
  String _pin = '';
  bool _isError = false;
  Timer? _errorResetTimer;
  late AnimationController _shakeController;
  late Animation<double> _shakeAnimation;

  @override
  void initState() {
    super.initState();
    _shakeController = AnimationController(
      duration: const Duration(milliseconds: 350),
      vsync: this,
    );
    _shakeAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: -10.0), weight: 1),
      TweenSequenceItem(tween: Tween(begin: -10.0, end: 10.0), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 10.0, end: -8.0), weight: 2),
      TweenSequenceItem(tween: Tween(begin: -8.0, end: 8.0), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 8.0, end: 0.0), weight: 1),
    ]).animate(CurvedAnimation(parent: _shakeController, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _errorResetTimer?.cancel();
    _shakeController.dispose();
    super.dispose();
  }

  void _onDigit(String digit) {
    if (_pin.length >= 8) return;

    try {
      HapticFeedback.lightImpact();
    } catch (_) {}

    _errorResetTimer?.cancel();

    setState(() {
      _pin += digit;
      _isError = false;
    });

    final security = Provider.of<SecurityService>(context, listen: false);
    if (_pin.length >= 4) {
      final ok = security.verifyPinSync(_pin);
      if (ok) {
        try {
          HapticFeedback.mediumImpact();
        } catch (_) {}
      } else if (_pin.length >= security.pinLength || _pin.length >= 8) {
        _triggerError();
      }
    }
  }

  void _triggerError() {
    try {
      HapticFeedback.heavyImpact();
    } catch (_) {}

    setState(() {
      _isError = true;
    });
    _shakeController.forward(from: 0.0);

    _errorResetTimer?.cancel();
    _errorResetTimer = Timer(const Duration(milliseconds: 400), () {
      if (mounted) {
        setState(() {
          _pin = '';
          _isError = false;
        });
      }
    });
  }

  void _onBackspace() {
    try {
      HapticFeedback.selectionClick();
    } catch (_) {}

    _errorResetTimer?.cancel();

    if (_pin.isNotEmpty) {
      setState(() {
        _pin = _pin.substring(0, _pin.length - 1);
        _isError = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // High-contrast, tactile color palette
    final buttonBgColor = isDark
        ? const Color(0xFF26262C)
        : const Color(0xFFE4E4EB);
    final buttonTextColor = isDark
        ? Colors.white
        : const Color(0xFF151518);
    final buttonBorderColor = isDark
        ? Colors.white.withOpacity(0.14)
        : Colors.black.withOpacity(0.1);

    final dotCount = _pin.length > 4 ? _pin.length : 4;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Top glowing Lock Emblem
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: (_isError ? theme.colorScheme.error : theme.colorScheme.primary).withOpacity(0.12),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: (_isError ? theme.colorScheme.error : theme.colorScheme.primary).withOpacity(0.35),
                        width: 1.5,
                      ),
                    ),
                    child: Icon(
                      _isError ? Icons.lock_open_rounded : Icons.lock_rounded,
                      size: 38,
                      color: _isError ? theme.colorScheme.error : theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'SECURITY LOCK',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 2.2,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _isError ? 'Incorrect PIN, please try again' : 'Enter your PIN to access directives',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: _isError ? FontWeight.w600 : FontWeight.normal,
                      color: _isError ? theme.colorScheme.error : theme.colorScheme.onSurface.withOpacity(0.7),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // PIN indicator dots with animated highlight and shake
                  AnimatedBuilder(
                    animation: _shakeAnimation,
                    builder: (context, child) {
                      return Transform.translate(
                        offset: Offset(_shakeAnimation.value, 0),
                        child: child,
                      );
                    },
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(dotCount, (index) {
                        final isFilled = index < _pin.length;
                        return AnimatedContainer(
                          duration: const Duration(milliseconds: 120),
                          margin: const EdgeInsets.symmetric(horizontal: 7),
                          width: 15,
                          height: 15,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isFilled
                                ? (_isError ? theme.colorScheme.error : theme.colorScheme.primary)
                                : Colors.transparent,
                            border: Border.all(
                              color: isFilled
                                  ? (_isError ? theme.colorScheme.error : theme.colorScheme.primary)
                                  : theme.colorScheme.onSurface.withOpacity(0.35),
                              width: 2,
                            ),
                            boxShadow: isFilled
                                ? [
                                    BoxShadow(
                                      color: (_isError ? theme.colorScheme.error : theme.colorScheme.primary)
                                          .withOpacity(0.45),
                                      blurRadius: 8,
                                      spreadRadius: 1,
                                    ),
                                  ]
                                : null,
                          ),
                        );
                      }),
                    ),
                  ),
                  const SizedBox(height: 32),

                  // Keypad grid with ultra-responsive, zero-latency circular touch buttons
                  Column(
                    children: [
                      ['1', '2', '3'],
                      ['4', '5', '6'],
                      ['7', '8', '9'],
                      ['', '0', 'DEL'],
                    ].map((row) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: row.map((digit) {
                            if (digit.isEmpty) {
                              return const SizedBox(width: 72, height: 72);
                            }
                            if (digit == 'DEL') {
                              return _buildKeypadButton(
                                child: Icon(
                                  Icons.backspace_outlined,
                                  size: 24,
                                  color: buttonTextColor,
                                ),
                                bgColor: buttonBgColor.withOpacity(0.65),
                                borderColor: buttonBorderColor,
                                splashColor: theme.colorScheme.primary.withOpacity(0.2),
                                onTap: _onBackspace,
                              );
                            }
                            return _buildKeypadButton(
                              child: Text(
                                digit,
                                style: TextStyle(
                                  fontSize: 26,
                                  fontWeight: FontWeight.w600,
                                  color: buttonTextColor,
                                ),
                              ),
                              bgColor: buttonBgColor,
                              borderColor: buttonBorderColor,
                              splashColor: theme.colorScheme.primary.withOpacity(0.25),
                              onTap: () => _onDigit(digit),
                            );
                          }).toList(),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildKeypadButton({
    required Widget child,
    required Color bgColor,
    required Color borderColor,
    required Color splashColor,
    required VoidCallback onTap,
  }) {
    return Container(
      width: 72,
      height: 72,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: bgColor,
        border: Border.all(color: borderColor, width: 1.2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.12),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          customBorder: const CircleBorder(),
          splashColor: splashColor,
          highlightColor: splashColor.withOpacity(0.15),
          onTapDown: (_) {
            try {
              HapticFeedback.lightImpact();
            } catch (_) {}
          },
          onTap: onTap,
          child: Center(child: child),
        ),
      ),
    );
  }
}
