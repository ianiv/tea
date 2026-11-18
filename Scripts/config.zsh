# Signing configuration shared by build.sh and Scripts/release.sh. Sourced, not run.

# tea_read_config <file> <required>
# Reads KEY=VALUE lines from <file> into globals, without sourcing or expanding anything.
# Blank lines and lines starting with # are skipped; whitespace around the key, = and value
# is trimmed, and one pair of matching surrounding quotes is stripped. A key already set to
# a non-empty value (from the environment) is left alone, so the environment beats the file.
# A missing file is fine unless <required> is 1. An unknown key, a repeated key or a
# malformed line exits 1, naming the file and line.
tea_read_config() {
  local file=$1 required=${2:-0} line key value n=0
  local -a allowed=(TEA_TEAM_ID TEA_SIGN_IDENTITY TEA_RELEASE_IDENTITY TEA_NOTARY_PROFILE)
  local -A seen
  if [[ ! -e $file || -d $file ]]; then
    (( ! required )) && return 0
    echo "error: config file $file not found" >&2
    exit 1
  fi
  while IFS= read -r line || [[ -n $line ]]; do
    (( ++n ))
    [[ $line =~ '^[[:space:]]*(#.*)?$' ]] && continue
    if [[ ! $line =~ '^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*[^[:space:]])?[[:space:]]*$' ]]; then
      echo "error: $file:$n: expected KEY=VALUE" >&2
      exit 1
    fi
    key=$match[1]
    value=${match[2]-}
    if (( ! ${allowed[(Ie)$key]} )); then
      echo "error: $file:$n: unknown key $key (expected one of: ${(j:, :)allowed})" >&2
      exit 1
    fi
    if [[ -n ${seen[$key]-} ]]; then
      echo "error: $file:$n: $key is already set on line ${seen[$key]}" >&2
      exit 1
    fi
    seen[$key]=$n
    if (( ${#value} >= 2 )) && [[ ( $value == \"*\" ) || ( $value == \'*\' ) ]] && [[ ${value[1]} == ${value[-1]} ]]; then
      value=${value[2,-2]}
    fi
    [[ -n ${(P)key:-} ]] || typeset -g "$key=$value"
  done < "$file"
}

# tea_identities: the keychain's valid code-signing identities, as `<sha1> "<name>"` lines.
tea_identities() {
  local ids
  # Captured first: under pipefail, a consumer exiting early could fail the pipeline.
  ids=$(security find-identity -v -p codesigning 2>/dev/null) || true
  print -r -- "$ids"
}

# tea_cert_team <sha1> <name>: the team ID in the OU of that certificate's subject, or
# nothing. An identity's team is read from its certificate, never from its name: the
# parenthesised ID in an "Apple Development: …" name is personal, not the team.
tea_cert_team() {
  local sha1=${(U)1} name=$2 pems pem subject
  pems=$(security find-certificate -a -Z -p -c "$name" 2>/dev/null) || return 0
  pem=$(awk -v h="$sha1" '
    /^SHA-1 hash:/ { on = (toupper($3) == h); next }
    on { print }
    on && /-----END CERTIFICATE-----/ { exit }
  ' <<<"$pems") || return 0
  [[ -n $pem ]] || return 0
  subject=$(openssl x509 -noout -subject <<<"$pem" 2>/dev/null) || return 0
  if [[ $subject =~ 'OU ?= ?([A-Z0-9]{10})' ]]; then
    print -r -- $match[1]
  fi
  return 0
}
