import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bridge/widgets.dart';

Widget wrap(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

DeviceCard buildCard({
  String name = 'iPhone',
  bool isGateway = false,
  bool isCurrentDevice = false,
  bool isOwner = false,
  List<String> simChips = const [],
  VoidCallback? onRemove,
}) => DeviceCard(
  name: name,
  statusLine: 'Client · Online now',
  isGateway: isGateway,
  online: true,
  isCurrentDevice: isCurrentDevice,
  isOwner: isOwner,
  currentDeviceLabel: 'This phone',
  ownerLabel: 'Owner',
  simChips: simChips,
  removeLabel: 'Remove',
  onRemove: onRemove,
);

void main() {
  testWidgets('offers no removal control when the viewer may not remove', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(buildCard()));
    expect(find.text('Remove'), findsNothing);
  });

  testWidgets('offers removal to the owner and reports the tap', (
    tester,
  ) async {
    var removed = false;
    await tester.pumpWidget(wrap(buildCard(onRemove: () => removed = true)));
    expect(find.text('Remove'), findsOneWidget);
    await tester.tap(find.text('Remove'));
    expect(removed, isTrue);
  });

  testWidgets('never offers to remove the phone you are holding', (
    tester,
  ) async {
    // The owner's own card must route to "Leave bridge" instead.
    await tester.pumpWidget(
      wrap(buildCard(isCurrentDevice: true, isOwner: true)),
    );
    expect(find.text('Remove'), findsNothing);
    expect(find.text('THIS PHONE'), findsOneWidget);
    expect(find.text('OWNER'), findsOneWidget);
  });

  testWidgets('shows the SIM lines a gateway provides', (tester) async {
    await tester.pumpWidget(
      wrap(
        buildCard(
          name: 'Android gateway',
          isGateway: true,
          simChips: const ['Telekom · +4915112345678', 'o2 · SIM 2'],
        ),
      ),
    );
    expect(find.text('Telekom · +4915112345678'), findsOneWidget);
    expect(find.text('o2 · SIM 2'), findsOneWidget);
    expect(find.text('Android gateway'), findsOneWidget);
  });
}
