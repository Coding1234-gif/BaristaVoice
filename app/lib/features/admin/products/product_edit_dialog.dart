import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/menu.dart';
import '../../../state/admin_providers.dart';

/// Add/edit form for a single product. Shared by the Products screen and
/// the extracted-menu review flow so there's one place that knows how to
/// edit a [MenuItem].
class ProductEditDialog extends ConsumerStatefulWidget {
  final MenuItem? initial;
  final String cafeId;

  const ProductEditDialog({super.key, this.initial, required this.cafeId});

  static Future<MenuItem?> show(
    BuildContext context, {
    MenuItem? initial,
    required String cafeId,
  }) {
    return showDialog<MenuItem>(
      context: context,
      builder: (_) => ProductEditDialog(initial: initial, cafeId: cafeId),
    );
  }

  @override
  ConsumerState<ProductEditDialog> createState() => _ProductEditDialogState();
}

class _ProductEditDialogState extends ConsumerState<ProductEditDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _description;
  late final TextEditingController _category;
  late final TextEditingController _price;
  late bool _available;
  String? _imageUrl;
  bool _uploadingImage = false;
  String? _error;

  MenuItem? get _initial => widget.initial;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: _initial?.name ?? '');
    _description = TextEditingController(text: _initial?.description ?? '');
    _category = TextEditingController(text: _initial?.category ?? '');
    _price = TextEditingController(text: _initial != null ? _initial!.basePrice.toStringAsFixed(2) : '');
    _available = _initial?.available ?? true;
    _imageUrl = _initial?.imageUrl;
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _category.dispose();
    _price.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image, withData: true);
    final file = result?.files.single;
    if (file?.bytes == null) return;

    setState(() => _uploadingImage = true);
    try {
      final url = await ref.read(cafeAdminRepositoryProvider).uploadProductImage(
            cafeId: widget.cafeId,
            bytes: file!.bytes!,
            filename: file.name,
          );
      setState(() => _imageUrl = url);
    } catch (e) {
      setState(() => _error = 'Could not upload image: $e');
    } finally {
      if (mounted) setState(() => _uploadingImage = false);
    }
  }

  void _save() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final price = double.tryParse(_price.text.trim());
    if (price == null || price < 0) {
      setState(() => _error = 'Enter a valid price');
      return;
    }

    final base = _initial ??
        MenuItem(id: '', name: '', description: '', category: 'Other', basePrice: 0);

    final updated = base.copyWith(
      name: _name.text.trim(),
      description: _description.text.trim(),
      category: _category.text.trim().isEmpty ? 'Other' : _category.text.trim(),
      basePrice: price,
      available: _available,
      imageUrl: _imageUrl,
    );

    Navigator.of(context).pop(updated);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_initial == null ? 'Add product' : 'Edit product'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ),
                Center(
                  child: GestureDetector(
                    onTap: _uploadingImage ? null : _pickImage,
                    child: Container(
                      width: 96,
                      height: 96,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF2F2F7),
                        borderRadius: BorderRadius.circular(12),
                        image: _imageUrl != null
                            ? DecorationImage(image: NetworkImage(_imageUrl!), fit: BoxFit.cover)
                            : null,
                      ),
                      child: _uploadingImage
                          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                          : (_imageUrl == null
                              ? const Icon(Icons.add_a_photo_outlined, color: Colors.black38)
                              : null),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Name'),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _description,
                  decoration: const InputDecoration(labelText: 'Description'),
                  maxLines: 2,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _category,
                        decoration: const InputDecoration(labelText: 'Category'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _price,
                        decoration: const InputDecoration(labelText: 'Price', prefixText: '£'),
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        validator: (v) => (v == null || double.tryParse(v.trim()) == null) ? 'Invalid' : null,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Available'),
                  subtitle: const Text('Shown as in-stock to customers', style: TextStyle(fontSize: 12)),
                  value: _available,
                  onChanged: (v) => setState(() => _available = v),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
