String cleanHandle(String handle) {
  return handle.toLowerCase().replaceAll(
        RegExp(r'[^a-z0-9\-]'),
        '',
      );
}
