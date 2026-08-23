#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
sign_app="$project_root/scripts/sign-app.sh"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/photosindex-signing.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT

app_path="$test_root/PhotosIndex.app"
entitlements_path="$test_root/PhotosIndex.entitlements"
mkdir -p "$app_path"
touch "$entitlements_path"

fake_security="$test_root/security"
fake_security_without_development="$test_root/security-without-development"
fake_security_must_not_run="$test_root/security-must-not-run"
fake_codesign="$test_root/codesign"

cat > "$fake_security" <<'SCRIPT'
#!/bin/zsh
print -r -- '  1) AAAA "Developer ID Application: Example (TEAM123)"'
print -r -- '  2) BBBB "Apple Development: Local Developer (TEAM123)"'
SCRIPT

cat > "$fake_security_without_development" <<'SCRIPT'
#!/bin/zsh
print -r -- '  1) AAAA "Developer ID Application: Example (TEAM123)"'
SCRIPT

cat > "$fake_security_must_not_run" <<'SCRIPT'
#!/bin/zsh
exit 99
SCRIPT

cat > "$fake_codesign" <<'SCRIPT'
#!/bin/zsh
print -rl -- "$@" > "$PHOTOSINDEX_CODESIGN_LOG"
SCRIPT

chmod 0755 \
  "$fake_security" \
  "$fake_security_without_development" \
  "$fake_security_must_not_run" \
  "$fake_codesign"

fail() {
  print -u2 -r -- "FAIL: $1"
  exit 1
}

assert_argument_pair() {
  local log_file=$1
  local option=$2
  local expected=$3
  local actual
  actual=$(awk -v option="$option" '$0 == option { getline; print; exit }' "$log_file")
  [[ "$actual" == "$expected" ]] || fail "$option expected '$expected', got '$actual'"
}

run_sign() {
  local log_file=$1
  local security_command=$2
  shift 2
  env \
    PHOTOSINDEX_CODESIGN_COMMAND="$fake_codesign" \
    PHOTOSINDEX_CODESIGN_LOG="$log_file" \
    PHOTOSINDEX_SECURITY_COMMAND="$security_command" \
    "$@" \
    zsh "$sign_app" "$app_path" "$entitlements_path"
}

default_log="$test_root/default.log"
run_sign "$default_log" "$fake_security"
assert_argument_pair "$default_log" --sign "Apple Development: Local Developer (TEAM123)"
assert_argument_pair "$default_log" --identifier "dev.pray.PhotosIndex"
assert_argument_pair "$default_log" --entitlements "$entitlements_path"

override_log="$test_root/override.log"
run_sign \
  "$override_log" \
  "$fake_security_must_not_run" \
  PHOTOSINDEX_DEVELOPMENT_IDENTITY="Apple Development: Explicit Developer (TEAM999)"
assert_argument_pair "$override_log" --sign "Apple Development: Explicit Developer (TEAM999)"

wrong_identity_log="$test_root/wrong-identity.log"
if run_sign \
  "$wrong_identity_log" \
  "$fake_security_must_not_run" \
  PHOTOSINDEX_DEVELOPMENT_IDENTITY="Developer ID Application: Distribution (TEAM999)" \
  > "$test_root/wrong-identity.stdout" 2> "$test_root/wrong-identity.stderr"; then
  fail "a distribution identity was accepted for development signing"
fi
grep -Fq "must start with 'Apple Development:'" "$test_root/wrong-identity.stderr" \
  || fail "wrong identity error was not actionable"
[[ ! -e "$wrong_identity_log" ]] || fail "codesign ran with a distribution identity"

missing_log="$test_root/missing.log"
if run_sign "$missing_log" "$fake_security_without_development" \
  > "$test_root/missing.stdout" 2> "$test_root/missing.stderr"; then
  fail "development signing succeeded without an Apple Development identity"
fi
grep -Fq "Apple Development signing identity" "$test_root/missing.stderr" \
  || fail "missing identity error was not actionable"
[[ ! -e "$missing_log" ]] || fail "codesign ran after identity discovery failed"

adhoc_log="$test_root/adhoc.log"
run_sign \
  "$adhoc_log" \
  "$fake_security_must_not_run" \
  PHOTOSINDEX_SIGNING_MODE=adhoc
assert_argument_pair "$adhoc_log" --sign -

invalid_log="$test_root/invalid.log"
if run_sign "$invalid_log" "$fake_security_must_not_run" \
  PHOTOSINDEX_SIGNING_MODE=release \
  > "$test_root/invalid.stdout" 2> "$test_root/invalid.stderr"; then
  fail "unsupported signing mode succeeded"
fi
grep -Fq "Unsupported PHOTOSINDEX_SIGNING_MODE" "$test_root/invalid.stderr" \
  || fail "invalid mode error was not actionable"
[[ ! -e "$invalid_log" ]] || fail "codesign ran for an invalid signing mode"

print -r -- "sign-app tests passed"
