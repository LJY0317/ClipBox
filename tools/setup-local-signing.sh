#!/bin/sh
set -eu

# Creates a ClipBox-only self-signed code-signing identity for local development.
# The private key is imported into the user's login Keychain. Temporary key
# material is encrypted, mode 0600 (via umask 077), and removed on exit.

identity_name=${CLIPBOX_LOCAL_SIGNING_IDENTITY:-"ClipBox Local Development Code Signing"}
login_keychain=$(/usr/bin/security default-keychain -d user | /usr/bin/tr -d '"' | /usr/bin/sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

if [ -z "$login_keychain" ]; then
    printf '%s\n' 'Could not determine the user login Keychain.' >&2
    exit 1
fi

has_valid_identity() {
    /usr/bin/security find-identity -v -p codesigning "$login_keychain" 2>/dev/null \
        | /usr/bin/grep -F "\"$identity_name\"" >/dev/null 2>&1
}

if has_valid_identity; then
    printf 'ClipBox local signing identity already available: %s\n' "$identity_name"
    exit 0
fi

# Never overwrite or delete unrelated/existing user certificate material.
if /usr/bin/security find-certificate -a -c "$identity_name" "$login_keychain" 2>/dev/null \
    | /usr/bin/grep -q .; then
    printf '%s\n' "A certificate named '$identity_name' already exists but is not a valid code-signing identity." >&2
    printf '%s\n' 'Refusing to overwrite it. Inspect that certificate in Keychain Access before retrying.' >&2
    exit 1
fi

openssl=/usr/bin/openssl
if [ ! -x "$openssl" ]; then
    printf '%s\n' 'The system OpenSSL/LibreSSL tool is unavailable.' >&2
    exit 1
fi

umask 077
temp_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/clipbox-local-signing.XXXXXX")
password=$($openssl rand -hex 24)
certificate_added=0

cleanup() {
    status=$?
    if [ "$status" -ne 0 ] && [ "$certificate_added" -eq 1 ]; then
        /usr/bin/security delete-identity -c "$identity_name" -t "$login_keychain" >/dev/null 2>&1 || true
    fi
    /bin/rm -rf "$temp_dir"
    exit "$status"
}
trap cleanup EXIT HUP INT TERM

cat > "$temp_dir/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no

[dn]
CN = $identity_name
O = ClipBox Local Development

[ext]
basicConstraints = critical,CA:true
keyUsage = critical,digitalSignature,keyCertSign
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF

# Keep private-key material encrypted before it reaches Keychain.
KEYPASS=$password $openssl genrsa -aes256 -passout env:KEYPASS -out "$temp_dir/private-key.pem" 2048 >/dev/null 2>&1
KEYPASS=$password $openssl req -x509 -new -sha256 -days 3650 \
    -config "$temp_dir/openssl.cnf" \
    -key "$temp_dir/private-key.pem" -passin env:KEYPASS \
    -out "$temp_dir/certificate.pem" >/dev/null 2>&1
KEYPASS=$password P12PASS=$password $openssl pkcs12 -export -name "$identity_name" \
    -inkey "$temp_dir/private-key.pem" -in "$temp_dir/certificate.pem" \
    -passin env:KEYPASS -passout env:P12PASS \
    -out "$temp_dir/identity.p12" >/dev/null 2>&1

# Restrict imported-key access to codesign. The trust setting is user-scoped
# and constrained to the codeSign policy; it is not a system-wide trust change.
/usr/bin/security import "$temp_dir/identity.p12" -k "$login_keychain" \
    -P "$password" -T /usr/bin/codesign >/dev/null
certificate_added=1
/usr/bin/security add-trusted-cert -r trustRoot -p codeSign \
    -k "$login_keychain" "$temp_dir/certificate.pem" >/dev/null

if ! has_valid_identity; then
    printf '%s\n' 'The certificate was created, but macOS did not expose it as a valid code-signing identity.' >&2
    exit 1
fi

printf 'Created ClipBox local development signing identity: %s\n' "$identity_name"
printf '%s\n' 'Trust scope: current user, codeSign policy only.'
printf '%s\n' 'This identity is for local development only; it is not Developer ID signing or notarization.'
