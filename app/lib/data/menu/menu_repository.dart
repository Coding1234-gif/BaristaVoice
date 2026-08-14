import '../../models/menu.dart';
import 'seed_menu.dart';

/// Abstraction so the active menu source can move from the hardcoded seed
/// (Phase 1) to a Supabase-backed, owner-edited menu (Phase 3) without
/// touching any UI or conversational code.
abstract class MenuRepository {
  Future<CafeMenu> getActiveMenu();
}

class SeedMenuRepository implements MenuRepository {
  @override
  Future<CafeMenu> getActiveMenu() async => seedMenu;
}
