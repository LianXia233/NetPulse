import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('minimal', (tester) async {
    print('pump start');
    await tester.pumpWidget(const MaterialApp(home: Text('hi')));
    print('pump done');
    expect(find.text('hi'), findsOneWidget);
  });
}
