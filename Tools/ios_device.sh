#!/bin/bash
# Shared reachability checks for `xcrun devicectl`. The command documents its
# JSON file as the only supported interface for scripts, so never infer state
# or identity from a human-formatted device row.

IOS_DEVICE_MOBILE_FILTER="hardwareProperties.deviceType == 'iPhone' OR hardwareProperties.deviceType == 'iPad'"
IOS_DEVICE_REACHABLE_FILTER="State == 'connected' OR State == 'available (paired)'"

is_ios_device_uuid() {
  [[ "$1" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]
}

normalized_ios_device_uuid() {
  tr '[:lower:]' '[:upper:]' <<< "$1"
}

first_ios_device_identifier_matching() {
  local filter="$1"
  local json_path identifier
  json_path=$(mktemp "${TMPDIR:-/tmp}/heiko-devicectl.XXXXXX") || return 1

  if ! xcrun devicectl list devices --filter "$filter" --json-output "$json_path" >/dev/null 2>&1; then
    rm -f "$json_path"
    return 1
  fi
  identifier=$(plutil -extract result.devices.0.identifier raw -o - "$json_path" 2>/dev/null || true)
  rm -f "$json_path"
  is_ios_device_uuid "$identifier" || return 1
  normalized_ios_device_uuid "$identifier"
}

ios_device_with_uuid_is_reachable() {
  local uuid="$1"
  local normalized_uuid identifier
  is_ios_device_uuid "$uuid" || return 1
  normalized_uuid=$(normalized_ios_device_uuid "$uuid")

  identifier=$(first_ios_device_identifier_matching "(identifier == '$normalized_uuid') AND ($IOS_DEVICE_MOBILE_FILTER) AND ($IOS_DEVICE_REACHABLE_FILTER)" || true)
  [[ "$identifier" == "$normalized_uuid" ]]
}

first_reachable_ios_device_uuid() {
  first_ios_device_identifier_matching "($IOS_DEVICE_MOBILE_FILTER) AND ($IOS_DEVICE_REACHABLE_FILTER)"
}

reachable_ios_device_uuid_for_name() {
  local selector="$1"
  local json_path index=0 device_name identifier
  json_path=$(mktemp "${TMPDIR:-/tmp}/heiko-devicectl.XXXXXX") || return 1

  if ! xcrun devicectl list devices \
    --filter "($IOS_DEVICE_MOBILE_FILTER) AND ($IOS_DEVICE_REACHABLE_FILTER)" \
    --json-output "$json_path" >/dev/null 2>&1; then
    rm -f "$json_path"
    return 1
  fi

  # Compare JSON values locally instead of interpolating a device name into an
  # NSPredicate. Names containing apostrophes are valid selectors and must
  # not be able to alter the query that establishes reachability.
  while identifier=$(plutil -extract "result.devices.$index.identifier" raw -o - "$json_path" 2>/dev/null); do
    device_name=$(plutil -extract "result.devices.$index.deviceProperties.name" raw -o - "$json_path" 2>/dev/null || true)
    if [[ "$device_name" == "$selector" ]]; then
      rm -f "$json_path"
      is_ios_device_uuid "$identifier" || return 1
      normalized_ios_device_uuid "$identifier"
      return 0
    fi
    index=$((index + 1))
  done

  rm -f "$json_path"
  return 1
}

reachable_ios_device_uuid_for_selector() {
  local selector="$1"
  local normalized_selector

  if is_ios_device_uuid "$selector"; then
    normalized_selector=$(normalized_ios_device_uuid "$selector")
    first_ios_device_identifier_matching "(identifier == '$normalized_selector') AND ($IOS_DEVICE_MOBILE_FILTER) AND ($IOS_DEVICE_REACHABLE_FILTER)"
    return
  fi

  reachable_ios_device_uuid_for_name "$selector"
}
