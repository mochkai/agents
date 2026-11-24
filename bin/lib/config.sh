# shellcheck shell=bash
# Shared farm settings for the bin/ scripts: reads farm.conf (repo root) safely.
#   usage: source "$FARM/bin/lib/config.sh"; farm_config "$FARM"
# Only the known keys below are read; the file is parsed, never sourced, so it cannot run code.
# An environment variable with the same name wins over farm.conf, which wins over the default.
# Every value must be a non-negative integer; anything else falls back to the default with a warning.
#
# Keys (defaults):
#   USAGE_LIMIT_5H=75     5-hour window limit in percent (0 = off)
#   USAGE_LIMIT_WEEK=90   weekly window limit in percent (0 = off)
#   USAGE_MAX_AGE=600     seconds a cached state/usage.json reading is reused

# Known keys and their defaults (kept in sync with bin/watch.js)
FARM_CONFIG_DEFAULTS=(USAGE_LIMIT_5H=75 USAGE_LIMIT_WEEK=90 USAGE_MAX_AGE=600)

# Set every known key as a shell variable: environment, then <farm>/farm.conf, then the default.
#   farm_config <farm-dir>
farm_config() {
  local conf="$1/farm.conf" pair key def value line
  local -A file_vals=()
  if [ -f "$conf" ]; then
    while IFS= read -r line; do
      line="${line%$'\r'}"
      [[ "$line" =~ ^([A-Z0-9_]+)=(.*)$ ]] || continue
      key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
      # Allow a trailing "# comment", surrounding spaces and quotes
      value="${value%%#*}"; value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"
      value="${value#\"}"; value="${value%\"}"
      file_vals[$key]="$value"
    done < "$conf"
  fi
  for pair in "${FARM_CONFIG_DEFAULTS[@]}"; do
    key="${pair%%=*}"; def="${pair#*=}"
    if [ -n "${!key+x}" ]; then value="${!key}"          # environment wins
    elif [ -n "${file_vals[$key]+x}" ]; then value="${file_vals[$key]}"
    else value="$def"; fi
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
      echo "WARNING: $key='$value' is not a non-negative integer; using $def" >&2
      value="$def"
    fi
    printf -v "$key" '%s' "$((10#$value))"
  done
}
