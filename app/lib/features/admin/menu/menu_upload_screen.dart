import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/admin_theme.dart';
import '../../../state/admin_providers.dart';

enum _Stage { idle, uploading, extracting, done, error }

class MenuUploadScreen extends ConsumerStatefulWidget {
  const MenuUploadScreen({super.key});

  @override
  ConsumerState<MenuUploadScreen> createState() => _MenuUploadScreenState();
}

class _MenuUploadScreenState extends ConsumerState<MenuUploadScreen> {
  _Stage _stage = _Stage.idle;
  String? _error;
  int? _extractedCount;

  Future<void> _pickAndUpload() async {
    final cafeId = ref.read(activeCafeIdProvider);
    if (cafeId == null) return;

    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'png', 'jpg', 'jpeg', 'webp'],
      withData: true,
    );
    final file = result?.files.single;
    if (file?.bytes == null) return;

    setState(() {
      _stage = _Stage.uploading;
      _error = null;
      _extractedCount = null;
    });

    try {
      final repo = ref.read(cafeAdminRepositoryProvider);
      final ext = (file!.extension ?? '').toLowerCase();
      final sourceType = ext == 'pdf' ? 'pdf' : 'image';

      final uploadId = await repo.uploadMenuFile(
        cafeId: cafeId,
        bytes: file.bytes!,
        filename: file.name,
        sourceType: sourceType,
      );

      setState(() => _stage = _Stage.extracting);

      final extraction = await repo.triggerExtraction(uploadId);

      ref.invalidate(menuItemsProvider);
      ref.invalidate(menuUploadsProvider);

      setState(() {
        _stage = _Stage.done;
        _extractedCount = extraction.count;
      });
    } catch (e) {
      setState(() {
        _stage = _Stage.error;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Upload menu')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: _buildContent(context),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    switch (_stage) {
      case _Stage.uploading:
      case _Stage.extracting:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 20),
            Text(
              _stage == _Stage.uploading ? 'Uploading file…' : 'Reading your menu with AI…',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const Text(
              'This can take up to a minute for a longer menu.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.black54, fontSize: 13),
            ),
          ],
        );

      case _Stage.done:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle_outline, color: adminSuccess, size: 40),
            const SizedBox(height: 16),
            Text(
              '${_extractedCount ?? 0} product${_extractedCount == 1 ? '' : 's'} detected. Review before publishing.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => context.go('/admin/menu'),
              child: const Text('Review products'),
            ),
          ],
        );

      case _Stage.error:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error, size: 40),
            const SizedBox(height: 16),
            Text(_error ?? 'Something went wrong.', textAlign: TextAlign.center),
            const SizedBox(height: 20),
            OutlinedButton(onPressed: _pickAndUpload, child: const Text('Try again')),
          ],
        );

      case _Stage.idle:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.upload_file_outlined, size: 40, color: adminSeedColor),
            const SizedBox(height: 16),
            const Text('Upload a PDF or photo of your menu', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            const Text(
              'AI will read it and detect products for you to review — nothing goes live until you publish.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.black54, fontSize: 13),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _pickAndUpload,
              icon: const Icon(Icons.upload_file_outlined, size: 18),
              label: const Text('Choose file'),
            ),
          ],
        );
    }
  }
}
