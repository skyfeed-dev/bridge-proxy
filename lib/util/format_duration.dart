String formatDuration(int millis) {
  millis = (millis / 1000).round();
  if (millis < 60 * 60) {
    return '${(millis / 60).floor()}:${(millis % 60).toString().padLeft(2, '0')}';
  } else {
    return '${(millis / (60 * 60)).floor()}:${(millis / 60).floor() % 60}:${(millis % 60).toString().padLeft(2, '0')}';
  }
}
