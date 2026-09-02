import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/security/security_service.dart';

class PanicDecoyView extends StatefulWidget {
  const PanicDecoyView({super.key});

  @override
  State<PanicDecoyView> createState() => _PanicDecoyViewState();
}

class _PanicDecoyViewState extends State<PanicDecoyView> {
  String _display = '0';
  double _firstNum = 0;
  String _operation = '';
  bool _shouldReset = false;

  void _onKeyPress(String key) {
    setState(() {
      if (key == 'C') {
        _display = '0';
        _firstNum = 0;
        _operation = '';
      } else if (key == '+' || key == '-' || key == '×' || key == '÷') {
        _firstNum = double.tryParse(_display) ?? 0;
        _operation = key;
        _shouldReset = true;
      } else if (key == '=') {
        // Secret unlock sequence check: if display is "7777" and "=" is pressed
        if (_display == '7777') {
          Provider.of<SecurityService>(context, listen: false).exitPanic();
          return;
        }

        final secondNum = double.tryParse(_display) ?? 0;
        double result = 0;
        switch (_operation) {
          case '+':
            result = _firstNum + secondNum;
            break;
          case '-':
            result = _firstNum - secondNum;
            break;
          case '×':
            result = _firstNum * secondNum;
            break;
          case '÷':
            result = secondNum != 0 ? _firstNum / secondNum : 0;
            break;
          default:
            result = secondNum;
        }
        _display = result.toString().endsWith('.0')
            ? result.toInt().toString()
            : result.toString();
        _operation = '';
        _shouldReset = true;
      } else {
        if (_display == '0' || _shouldReset) {
          _display = key;
          _shouldReset = false;
        } else {
          _display += key;
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E1E1E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1E1E),
        elevation: 0,
        title: GestureDetector(
          onLongPress: () {
            Provider.of<SecurityService>(context, listen: false).exitPanic();
          },
          child: const Text(
            'Calculator',
            style: TextStyle(color: Colors.white70, fontSize: 18),
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline_rounded, color: Colors.white60),
            tooltip: 'How to Exit',
            onPressed: () {
              showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  backgroundColor: const Color(0xFF2C2C2C),
                  title: const Row(
                    children: [
                      Icon(Icons.info_outline_rounded, color: Colors.orangeAccent),
                      SizedBox(width: 10),
                      Text('Calculator Decoy', style: TextStyle(color: Colors.white)),
                    ],
                  ),
                  content: const Text(
                    'Enter 7777 = to exit and return to the main application.',
                    style: TextStyle(fontSize: 15, color: Colors.white70, height: 1.4),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('OK', style: TextStyle(color: Colors.orangeAccent)),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Display
            Expanded(
              child: Container(
                alignment: Alignment.bottomRight,
                padding: const EdgeInsets.all(24),
                child: Text(
                  _display,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 48,
                    fontWeight: FontWeight.w300,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            const Divider(color: Colors.white12, height: 1),
            // Keypad
            _buildKeypad(),
          ],
        ),
      ),
    );
  }

  Widget _buildKeypad() {
    final rows = [
      ['C', '±', '%', '÷'],
      ['7', '8', '9', '×'],
      ['4', '5', '6', '-'],
      ['1', '2', '3', '+'],
      ['0', '.', '='],
    ];

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: rows.map((row) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: row.map((key) {
                final isOp = ['÷', '×', '-', '+', '='].contains(key);
                final isZero = key == '0';
                return Expanded(
                  flex: isZero ? 2 : 1,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        backgroundColor: isOp
                            ? const Color(0xFFFF9F0A)
                            : key == 'C' || key == '±' || key == '%'
                                ? const Color(0xFFA5A5A5)
                                : const Color(0xFF333333),
                        foregroundColor:
                            key == 'C' || key == '±' || key == '%' ? Colors.black : Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30),
                        ),
                      ),
                      onPressed: () => _onKeyPress(key),
                      child: Text(
                        key,
                        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          );
        }).toList(),
      ),
    );
  }
}
