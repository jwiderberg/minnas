#!/usr/bin/env bash
#
# Load the signing and notarization secrets the release workflow needs
# (.github/workflows/release.yml) into the GitHub repository, with `gh`.
#
# You need, once, from your Apple Developer account:
#
#   1. A "Developer ID Application" certificate, exported with its private
#      key as a .p12 file. In Keychain Access: My Certificates, right-click
#      "Developer ID Application: <name> (<team>)", Export, file format
#      Personal Information Exchange (.p12), choose a password.
#      (Xcode > Settings > Accounts > Manage Certificates creates the
#      certificate if you do not have one; only the account holder can.)
#
#   2. An App Store Connect API key for notarytool: App Store Connect >
#      Users and Access > Integrations > Team Keys, role Developer. Download
#      the AuthKey_<KEYID>.p8 (offered once) and note the Key ID and the
#      Issuer ID shown on that page.
#
# Then:
#
#   bash scripts/release-secrets.sh \
#       --p12 ~/Desktop/DeveloperID.p12 \
#       --p8 ~/Downloads/AuthKey_ABC123XYZ.p8 --key-id ABC123XYZ \
#       --issuer 12345678-aaaa-bbbb-cccc-1234567890ab
#
# The script asks for the .p12 password without echo, checks that the .p12
# really holds a Developer ID Application certificate, and sets five
# repository secrets: DEVELOPER_ID_P12_BASE64, DEVELOPER_ID_P12_PASSWORD,
# NOTARY_KEY_P8_BASE64, NOTARY_KEY_ID, NOTARY_ISSUER_ID. No value is printed.
# Afterwards, delete the .p12 and .p8 files (it reminds you).
#
# Flags:
#   --repo <owner/name>  default: the repository `gh` resolves for this clone
#   --dry-run            check the inputs and print what would be set, set nothing
#
set -euo pipefail

P12=""
P8=""
KEY_ID=""
ISSUER=""
REPO=""
DRY_RUN=0

usage() {
    sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

need_arg() {
    if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "error: $1 needs a value" >&2
        exit 2
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --p12) need_arg "$@"; P12="$2"; shift ;;
        --p8) need_arg "$@"; P8="$2"; shift ;;
        --key-id) need_arg "$@"; KEY_ID="$2"; shift ;;
        --issuer) need_arg "$@"; ISSUER="$2"; shift ;;
        --repo) need_arg "$@"; REPO="$2"; shift ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown flag $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

fail() { echo "error: $*" >&2; exit 1; }

[[ -n "$P12" && -n "$P8" && -n "$KEY_ID" && -n "$ISSUER" ]] \
    || { usage >&2; fail "--p12, --p8, --key-id and --issuer are all required"; }
[[ -f "$P12" ]] || fail "no such file: $P12"
[[ -f "$P8" ]] || fail "no such file: $P8"
[[ "$KEY_ID" =~ ^[[:alnum:]]{8,}$ ]] || fail "--key-id should be the Key ID shown next to the key (letters and digits, usually 10)"
[[ "$ISSUER" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] \
    || fail "--issuer should be the UUID-shaped Issuer ID"
grep -q 'BEGIN PRIVATE KEY' "$P8" || fail "$P8 does not look like an App Store Connect API key (.p8)"

command -v gh >/dev/null || fail "gh (GitHub CLI) is not installed"
gh auth status >/dev/null 2>&1 || fail "gh is not logged in; run: gh auth login"
if [[ -z "$REPO" ]]; then
    REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
    [[ -n "$REPO" ]] || fail "could not resolve the repository; pass --repo owner/name"
fi

# The password is needed to open the .p12 for the check below and becomes a
# secret itself. Read without echo; never printed.
read -r -s -p "Password of $P12: " P12_PASSWORD
echo
[[ -n "$P12_PASSWORD" ]] || fail "empty password"

# Confirm the bundle holds a Developer ID Application certificate (and that
# the password opens it). The password reaches openssl on a private file
# descriptor, not in the environment or the argument list. -legacy is for
# OpenSSL 3 reading older PKCS#12 files.
p12_subject() {
    openssl pkcs12 "$@" -in "$P12" -nokeys -clcerts -passin fd:3 3<<<"$P12_PASSWORD" 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null || true
}
SUBJECT="$(p12_subject)"
[[ -n "$SUBJECT" ]] || SUBJECT="$(p12_subject -legacy)"
[[ -n "$SUBJECT" ]] || fail "could not open $P12 with that password"
grep -q 'Developer ID Application' <<<"$SUBJECT" \
    || fail "the certificate in $P12 is not a 'Developer ID Application' certificate: $SUBJECT"
echo "Certificate: $(sed -nE 's/.*CN *= *([^,/]*).*/\1/p' <<<"$SUBJECT")"
echo "Repository:  $REPO"

set_secret() {
    # $1 name; value on stdin
    if [[ $DRY_RUN -eq 1 ]]; then
        cat >/dev/null
        echo "  would set $1"
    else
        # No --body: gh reads the value from standard input.
        gh secret set "$1" --repo "$REPO" >/dev/null
        echo "  set $1"
    fi
}

echo "Secrets:"
base64 < "$P12" | tr -d '\n' | set_secret DEVELOPER_ID_P12_BASE64
printf '%s' "$P12_PASSWORD" | set_secret DEVELOPER_ID_P12_PASSWORD
base64 < "$P8" | tr -d '\n' | set_secret NOTARY_KEY_P8_BASE64
printf '%s' "$KEY_ID" | set_secret NOTARY_KEY_ID
printf '%s' "$ISSUER" | set_secret NOTARY_ISSUER_ID

echo
if [[ $DRY_RUN -eq 1 ]]; then
    echo "Dry run: nothing was set."
else
    echo "Done. Delete the exported files now that GitHub holds them:"
    echo "  rm -P '$P12' '$P8'"
    echo "Test the pipeline without publishing:"
    echo "  gh workflow run release.yml --repo $REPO -f publish=false"
fi
