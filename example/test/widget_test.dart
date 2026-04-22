import 'package:flutter_test/flutter_test.dart';

import 'package:live_photo_gallery_example/main.dart';

void main() {
  testWidgets('renders plugin example actions', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('Live Photo Gallery Example'), findsOneWidget);
    expect(find.text('请求相册权限'), findsOneWidget);
    expect(find.text('清理临时文件'), findsOneWidget);
  });
}
