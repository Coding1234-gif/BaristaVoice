import '../../models/menu.dart';

/// Every menu load is scoped to one café — there is no global/default menu
/// getter. A caller that hasn't resolved a café yet must not call this at
/// all (see currentCafeIdProvider / activeMenuProvider).
abstract class MenuRepository {
  Future<CafeMenu> getActiveMenu(String cafeId);
}
