import 'package:logger/logger.dart';
import 'package:atproto_bridge_proxy/server.dart';

final logger = Logger(
  printer: SimplePrinter(),
  // printer: LogfmtPrinter(),
  // printer: PrettyPrinter(),
  // output: ConsoleOutput(),
  filter: PrintEverythingFilter(),
);

class PrintEverythingFilter extends LogFilter {
  @override
  bool shouldLog(LogEvent event) {
    return true;
  }
}

void main(List<String> arguments) async {
  if (arguments.isEmpty) {
    throw 'Usage: bridge_proxy PUBLIC_PROXY_URL';
  }
  final server = BridgeProxyServer(
    service: arguments.length > 1 ? arguments[1] : 'bsky.social',
    logger: logger,
    serviceEndpoint: arguments[0],
  );
  await server.start();
}
