import 'package:flutter_test/flutter_test.dart';

import 'package:backup_foto/main.dart';

void main() {
  testWidgets('App starts without crashing', (WidgetTester tester) async {
    await tester.pumpWidget(const KirimFotoApp());
    await tester.pump();
    // Tidak boleh ada exception yang lolos (plugin izin tidak tersedia di
    // environment test, jadi app harus aman masuk ke state error/checking).
    expect(tester.takeException(), isNull);
    expect(find.byType(HomePage), findsOneWidget);
  });
}
