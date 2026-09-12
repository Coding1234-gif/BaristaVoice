import 'package:flutter/material.dart';

/// The typing alternative to [MicButton] — same role in the layout, same
/// "one thing the customer does to talk to the barista" spot, just text
/// instead of voice. Feeds `KioskController.submitTypedText`, which reuses
/// the exact same conversational pipeline a spoken utterance does.
class TypedInputBar extends StatefulWidget {
  final bool enabled;
  final void Function(String text) onSubmit;

  const TypedInputBar({super.key, required this.enabled, required this.onSubmit});

  @override
  State<TypedInputBar> createState() => _TypedInputBarState();
}

class _TypedInputBarState extends State<TypedInputBar> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    widget.onSubmit(text);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _controller,
            enabled: widget.enabled,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _submit(),
            decoration: const InputDecoration(
              hintText: "Type what you'd like…",
              border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(24))),
              contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filled(
          onPressed: widget.enabled ? _submit : null,
          icon: const Icon(Icons.send),
        ),
      ],
    );
  }
}
