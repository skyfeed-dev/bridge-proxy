import 'package:html2md/html2md.dart' as html2md;

String preprocessHtml(String html) {
  return html2md
      .convert(html)
      .replaceAllMapped(
        RegExp(r'\[[^\]]+\]\(([^\)]+)\)'),
        (match) => match.group(1) ?? '',
      )
      .replaceAll('\\>', '>');
}
