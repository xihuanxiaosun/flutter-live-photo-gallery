import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:live_photo_gallery_example/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('example app boots', (WidgetTester tester) async {
    app.main();
    await tester.pumpAndSettle();

    expect(find.text('Live Photo Gallery Example'), findsOneWidget);
    expect(find.text('请求相册权限'), findsOneWidget);
  });
}
