import 'package:flutter/material.dart';

/// Only mounted for a recently authenticated connection. Respect reduced motion.
class ConnectedDeviceLight extends StatefulWidget {
  const ConnectedDeviceLight({super.key});

  @override
  State<ConnectedDeviceLight> createState() => _ConnectedDeviceLightState();
}

class _ConnectedDeviceLightState extends State<ConnectedDeviceLight>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );
  late final Animation<double> _opacity = Tween<double>(
    begin: 0.35,
    end: 1,
  ).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _pulse.stop();
      _pulse.value = 1;
    } else if (!_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: '已连接',
    child: SizedBox.square(
      dimension: 24,
      child: Center(
        child: FadeTransition(
          opacity: _opacity,
          child: Container(
            width: 12,
            height: 12,
            decoration: const BoxDecoration(
              color: Color(0xFF16835D),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Color(0x5516835D),
                  blurRadius: 8,
                  spreadRadius: 2,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
