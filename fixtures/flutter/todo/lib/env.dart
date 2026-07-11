/// Live-mode switch. Values arrive ONLY via --dart-define / --dart-define-from-file
/// (see env.example.json); nothing is ever hardcoded or committed.
class Env {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
  static const testEmail = String.fromEnvironment('SUPABASE_TEST_EMAIL');
  static const testPassword = String.fromEnvironment('SUPABASE_TEST_PASSWORD');

  /// Both-or-neither: the smoke suite fails closed on a contradictory env
  /// (exactly one of url/key set) — see smoke_auth_test.dart's guard.
  static const isLive = supabaseUrl != '' && supabaseAnonKey != '';

  /// Cairn "local live" mode (W5): a real `cairn-server` + real docker
  /// Postgres + a pre-minted JWT, in place of a real Supabase project (W0b is
  /// operator-blocked — see docs/plans/flutter-supabase-plug-and-play-launch.md).
  /// [cairnWsUrl] is `cairn dev`'s printed ws:// URL; [cairnToken] is an
  /// HS256 JWT minted by `tool/mint_jwt.sh` against the same dev secret the
  /// server verifies (`CAIRN_SUPABASE_JWT_SECRET`) — its `sub` claim becomes
  /// both the account id and the tenant id (ADR-0011/0018). Mutually
  /// exclusive with Supabase live mode in practice (nothing enforces it —
  /// both are dev-only switches), and checked first in main.dart.
  static const cairnWsUrl = String.fromEnvironment('CAIRN_WS_URL');
  static const cairnToken = String.fromEnvironment('CAIRN_TOKEN');

  /// Both-or-neither, same fail-closed shape as [isLive].
  static const isCairnLive = cairnWsUrl != '' && cairnToken != '';
}
