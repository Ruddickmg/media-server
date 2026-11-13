#!/usr/bin/env bash
# Watch a laptop battery and re-arm charging when the embedded controller (EC)
# stops charging while AC is still connected.
#
# Target: Dell XPS 15 9530 (and similar Dells) whose EC silently stops taking
# power from the charger. The firmware keeps reporting "Charging" while the
# pack drains, and the observed symptoms are any of:
#   - current_now becomes unreadable,
#   - charge_now stops rising, or falls, while AC/online is still 1,
#   - status flips to Discharging although AC/online is 1.
# The only thing that reliably recovers it is physically replugging the
# charger, so every tier below is an attempt to reproduce that in software.
#
# The EC owns the charge state machine and USB-C PD; the OS can only poke the
# interfaces that are exposed. Tiers, cheapest first, each verified by checking
# that charge_now starts rising again:
#
#   ac-rebind       rebind ACPI0003:00 so the EC re-evaluates _PSR
#   battery-rebind  rebind PNP0C0A:00 so _BST/_BIF are re-read
#   ucsi            UCSI PPM reset via ucsi_acpi rebind, then a full
#                   typec/ucsi stack reload (closest software "replug")
#   dell-modes      toggle charge_types / Custom thresholds through Dell SMM
#   suspend         rtcwake -m mem for a few seconds (re-inits EC state)
#   ec-rebind       rebind the ACPI EC driver PNP0C09:00 (strong, opt-in)
#   reboot          last resort below a capacity floor (opt-in)
#
# The tier that last restarted charging is remembered in $STATE_DIR/last_tier
# and moved to the front of the ladder on the next fault, so recovery stays
# fast after the first success. Everything is logged to stdout, which systemd
# captures in the journal.

set -uo pipefail

BAT="${BAT:-/sys/class/power_supply/BAT0}"
AC="${AC:-/sys/class/power_supply/AC}"
INTERVAL="${INTERVAL:-20}"
WINDOW="${WINDOW:-180}"
# Charge must rise by this many thousandths of charge_full over WINDOW, or the
# pack counts as stalled. 2 permille of a 4089 mAh full charge is ~8 mAh, i.e.
# an average of ~160 mA over the window.
MIN_RISE_PERMILLE="${MIN_RISE_PERMILLE:-2}"
# Increase in charge_now (uAh) that counts as charging having resumed while
# verifying a tier.
MIN_RISE="${MIN_RISE:-2000}"
COOLDOWN="${COOLDOWN:-60}"
MAX_COOLDOWN="${MAX_COOLDOWN:-300}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-0}"
RESET_DWELL="${RESET_DWELL:-2}"
VERIFY_WAIT="${VERIFY_WAIT:-25}"
VERIFY_POLL="${VERIFY_POLL:-5}"
SUSTAINED_SECONDS="${SUSTAINED_SECONDS:-300}"
DRY_RUN="${DRY_RUN:-0}"
LEAVE_WORKING_MODE="${LEAVE_WORKING_MODE:-0}"
ENABLE_AC_REBIND="${ENABLE_AC_REBIND:-1}"
ENABLE_BATTERY_REBIND="${ENABLE_BATTERY_REBIND:-1}"
ENABLE_UCSI_RESET="${ENABLE_UCSI_RESET:-0}"
ENABLE_DELL_MODES="${ENABLE_DELL_MODES:-1}"
ENABLE_SUSPEND_RESET="${ENABLE_SUSPEND_RESET:-0}"
ENABLE_EC_RESET="${ENABLE_EC_RESET:-0}"
ENABLE_REBOOT_RESET="${ENABLE_REBOOT_RESET:-0}"
REBOOT_BELOW_CAPACITY="${REBOOT_BELOW_CAPACITY:-8}"
REBOOT_COOLDOWN="${REBOOT_COOLDOWN:-1800}"
SUSPEND_SECONDS="${SUSPEND_SECONDS:-8}"
SUSPEND_AFTER_FAILURES="${SUSPEND_AFTER_FAILURES:-0}"
UCSI_DEVICE="${UCSI_DEVICE:-USBC000:00}"
UCSI_DRIVER="${UCSI_DRIVER:-ucsi_acpi}"
AC_DEVICE="${AC_DEVICE:-ACPI0003:00}"
BAT_DEVICE="${BAT_DEVICE:-PNP0C0A:00}"
EC_DEVICE="${EC_DEVICE:-PNP0C09:00}"
STATE_DIR="${STATE_DIR:-${STATE_DIRECTORY:-/var/lib/battery-recharge-watch}}"
TAG="${TAG:-battery-recharge-watch}"
NOTIFY_SCRIPT="${NOTIFY_SCRIPT:-}"

mkdir -p "$STATE_DIR" 2>/dev/null || true
RESTORE_FILE="$STATE_DIR/restore.env"
LAST_TIER_FILE="$STATE_DIR/last_tier"
LAST_REBOOT_FILE="$STATE_DIR/last_reboot"

log() {
  printf '%s %s: %s\n' "$(date '+%F %T')" "$TAG" "$*"
}

notify() {
  [[ -n "$NOTIFY_SCRIPT" && -x "$NOTIFY_SCRIPT" ]] || return 0
  "$NOTIFY_SCRIPT" "$1" "$2" >/dev/null 2>&1 || true
}

read_attr() {
  local file=$1 value
  [[ -r "$file" ]] || return 1
  IFS= read -r value < "$file" || return 1
  printf '%s\n' "$value"
}

write_attr() {
  local file=$1 value=$2
  [[ -w "$file" ]] || return 1
  printf '%s\n' "$value" > "$file" 2>/dev/null
}

wait_for_readable() {
  local file=$1 i
  for (( i = 0; i < 15; i++ )); do
    [[ -r "$file" ]] && return 0
    sleep 1
  done
  return 1
}

active_mode() {
  local types
  types=$(read_attr "$BAT/charge_types") || return 1
  [[ "$types" == *'['*']'* ]] || return 1
  types=${types#*\[}
  printf '%s\n' "${types%%\]*}"
}

has_mode() {
  local types
  types=$(read_attr "$BAT/charge_types") || return 1
  [[ "$types" == *"$1"* ]]
}

battery_charge() { read_attr "$BAT/charge_now"; }
battery_full() { read_attr "$BAT/charge_full"; }
battery_status() { read_attr "$BAT/status"; }
battery_capacity() { read_attr "$BAT/capacity"; }
battery_current() { read_attr "$BAT/current_now"; }
ac_online() { read_attr "$AC/online"; }

# Charging stops when the pack reaches the configured end threshold; below it
# the EC is expected to be taking charge. Used to avoid firing at a held limit.
charge_limit() {
  local end
  end=$(read_attr "$BAT/charge_control_end_threshold") || end=100
  [[ "$end" =~ ^[0-9]+$ ]] || end=100
  printf '%s\n' "$end"
}

# One-line description of the Type-C/PD state, for the journal. This is the
# diagnostic that tells us whether the EC's PD stack is still enumerated.
typec_describe() {
  local p name role revision out=""
  for p in /sys/class/typec/port*; do
    [[ -e "$p" ]] || continue
    name=${p##*/}
    [[ "$name" =~ ^port[0-9]+$ ]] || continue
    role=$(read_attr "$p/power_role") || role="?"
    revision="none"
    if [[ -e "$p-partner" ]]; then
      revision=$(read_attr "$p-partner/usb_power_delivery_revision") || revision="?"
    fi
    out+="${name}(role=${role},partner_pd=${revision}) "
  done
  printf '%s' "${out:-no-ports}"
}

min_rise_window() {
  local full rise
  full=$(battery_full) || full=0
  if (( full > 0 )); then
    rise=$(( full * MIN_RISE_PERMILLE / 1000 ))
  else
    rise=$MIN_RISE
  fi
  (( rise < 1000 )) && rise=1000
  printf '%s\n' "$rise"
}

save_restore() {
  local mode=$1 start=$2 end=$3 tmp="$RESTORE_FILE.tmp"
  {
    printf 'ORIG_MODE=%q\n' "$mode"
    printf 'ORIG_START=%q\n' "$start"
    printf 'ORIG_END=%q\n' "$end"
  } > "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mv -f "$tmp" "$RESTORE_FILE"
}

restore_original() {
  [[ -f "$RESTORE_FILE" ]] || {
    rm -f "$RESTORE_FILE.tmp"
    return 0
  }
  # shellcheck source=/dev/null
  source "$RESTORE_FILE"
  log "restoring mode=${ORIG_MODE:-?} start=${ORIG_START:-?} end=${ORIG_END:-?}"
  # Start before end: the driver clamps the pair to a minimum 5% gap.
  if [[ -n "${ORIG_START:-}" ]]; then
    write_attr "$BAT/charge_control_start_threshold" "$ORIG_START" || true
  fi
  if [[ -n "${ORIG_END:-}" ]]; then
    write_attr "$BAT/charge_control_end_threshold" "$ORIG_END" || true
  fi
  if [[ -n "${ORIG_MODE:-}" ]] && has_mode "$ORIG_MODE"; then
    write_attr "$BAT/charge_types" "$ORIG_MODE" || true
  fi
  rm -f "$RESTORE_FILE"
}

cleanup() {
  restore_original
}
on_signal() {
  cleanup
  exit 0
}
trap cleanup EXIT
trap on_signal INT TERM

add_sample() {
  local ts=$1 charge=$2 cutoff s st
  local -a new=()
  samples+=("$ts:$charge")
  cutoff=$(( ts - WINDOW - INTERVAL ))
  for s in "${samples[@]}"; do
    st=${s%%:*}
    if (( st >= cutoff )); then
      new+=("$s")
    fi
  done
  samples=("${new[@]}")
}

# Print the net rise in charge_now across the window, or return 1 when the
# window is not yet full. This is the sign-agnostic fault signal: it does not
# care what current_now claims, only what the pack actually did.
trend_rise() {
  local n=${#samples[@]}
  (( n >= 2 )) || return 1
  local first=${samples[0]} last=${samples[$(( n - 1 ))]}
  local first_ts=${first%%:*} last_ts=${last%%:*}
  (( last_ts - first_ts >= WINDOW - INTERVAL )) || return 1
  printf '%s\n' $(( ${last##*:} - ${first##*:} ))
}

verify_charging() {
  local label=$1 start_charge start_time now charge delta
  # A tier that just rebound a driver may have momentarily removed the power
  # supply device; wait for it before sampling.
  wait_for_readable "$BAT/charge_now" || {
    log "$label: battery disappeared during reset"
    return 1
  }
  wait_for_readable "$AC/online" || {
    log "$label: AC device disappeared during reset"
    return 1
  }
  start_charge=$(battery_charge) || {
    log "$label: cannot read charge_now"
    return 1
  }
  start_time=$(date +%s)
  while true; do
    sleep "$VERIFY_POLL"
    if [[ "$(ac_online)" != "1" ]]; then
      log "$label: AC went offline during verification"
      return 1
    fi
    charge=$(battery_charge) || charge=""
    now=$(date +%s)
    delta="?"
    if [[ -n "$charge" ]]; then
      delta=$(( charge - start_charge ))
      if (( delta >= MIN_RISE )); then
        log "$label: charging resumed (+${delta} uAh in $(( now - start_time ))s)"
        return 0
      fi
    fi
    if (( now - start_time >= VERIFY_WAIT )); then
      log "$label: no increase after $(( now - start_time ))s (delta=${delta} uAh)"
      return 1
    fi
  done
}

# --- tiers ------------------------------------------------------------------

tier_ac_rebind() {
  local dir="/sys/bus/platform/drivers/ac"
  if [[ ! -e "$dir/$AC_DEVICE" ]]; then
    log "ac-rebind: $AC_DEVICE not bound to $dir"
    return 1
  fi
  log "ac-rebind: rebinding $AC_DEVICE"
  write_attr "$dir/unbind" "$AC_DEVICE" || {
    log "ac-rebind: unbind failed"
    return 1
  }
  sleep 1
  write_attr "$dir/bind" "$AC_DEVICE" || {
    log "ac-rebind: bind failed"
    wait_for_readable "$AC/online" || log "ac-rebind: AC did not come back"
    return 1
  }
  sleep "$RESET_DWELL"
  verify_charging "ac-rebind"
}

tier_battery_rebind() {
  local dir="/sys/bus/acpi/drivers/battery"
  if [[ ! -e "$dir/$BAT_DEVICE" ]]; then
    log "battery-rebind: $BAT_DEVICE not bound to $dir"
    return 1
  fi
  log "battery-rebind: rebinding $BAT_DEVICE"
  write_attr "$dir/unbind" "$BAT_DEVICE" || {
    log "battery-rebind: unbind failed"
    return 1
  }
  sleep 1
  write_attr "$dir/bind" "$BAT_DEVICE" || {
    log "battery-rebind: bind failed"
    wait_for_readable "$BAT/charge_now" || log "battery-rebind: battery did not come back"
    return 1
  }
  sleep "$RESET_DWELL"
  verify_charging "battery-rebind"
}

tier_ucsi() {
  local driver_dir="/sys/bus/platform/drivers/$UCSI_DRIVER" i

  log "ucsi: state before reset: $(typec_describe)"

  modprobe "$UCSI_DRIVER" 2>/dev/null || true
  if [[ ! -d "$driver_dir" ]]; then
    log "ucsi: $driver_dir is missing; cannot reset"
    return 1
  fi

  # ---- Tier A: unbind/rebind. The bind path runs the UCSI PPM_RESET ----
  if [[ ! -e "$driver_dir/$UCSI_DEVICE" ]]; then
    log "ucsi: $UCSI_DEVICE is not bound; binding it"
    write_attr "$driver_dir/bind" "$UCSI_DEVICE" || true
    sleep 2
  fi

  if [[ -e "$driver_dir/$UCSI_DEVICE" ]]; then
    log "ucsi: unbinding $UCSI_DEVICE from $UCSI_DRIVER"
    if write_attr "$driver_dir/unbind" "$UCSI_DEVICE"; then
      sleep 2
      log "ucsi: rebinding $UCSI_DEVICE to $UCSI_DRIVER (PPM reset)"
      write_attr "$driver_dir/bind" "$UCSI_DEVICE" || log "ucsi: rebind failed"
      sleep 5
      log "ucsi: state after rebind: $(typec_describe)"
      if verify_charging "ucsi PPM reset"; then
        return 0
      fi
    else
      log "ucsi: unbind failed"
    fi
  fi

  # ---- Tier B: reload the whole UCSI/typec stack. Stronger than a rebind:
  # it tears down and re-creates every typec port and PD object. ----
  log "ucsi: rebind did not restart charging; reloading the UCSI stack"
  modprobe -r "$UCSI_DRIVER" 2>/dev/null || true
  modprobe -r typec_ucsi 2>/dev/null || true
  modprobe -r typec 2>/dev/null || true
  sleep 2
  if ! modprobe "$UCSI_DRIVER" 2>/dev/null; then
    log "ucsi: failed to reload $UCSI_DRIVER"
    return 1
  fi
  for (( i = 0; i < 20; i++ )); do
    compgen -G '/sys/class/typec/port*' >/dev/null && break
    sleep 1
  done
  sleep 3
  log "ucsi: state after stack reload: $(typec_describe)"

  verify_charging "ucsi stack reload"
}

# The Dell SMM knobs change the charge profile but have never been observed to
# re-arm a stopped charger on this machine. They are kept as a cheap middle
# tier because they are harmless and may help on other models.
tier_dell_modes() {
  local orig_mode orig_start orig_end candidate=""

  orig_mode=$(active_mode) || orig_mode=""
  orig_start=$(read_attr "$BAT/charge_control_start_threshold") || orig_start=""
  orig_end=$(read_attr "$BAT/charge_control_end_threshold") || orig_end=""

  if [[ -z "$orig_mode" ]]; then
    log "dell-modes: cannot determine the active charge mode; skipping"
    return 1
  fi
  if ! save_restore "$orig_mode" "$orig_start" "$orig_end"; then
    log "dell-modes: cannot write restore state; skipping"
    return 1
  fi

  if [[ "$orig_mode" != "Standard" ]] && has_mode "Standard"; then
    candidate="Standard"
  elif [[ "$orig_mode" != "Adaptive" ]] && has_mode "Adaptive"; then
    candidate="Adaptive"
  elif [[ "$orig_mode" != "Fast" ]] && has_mode "Fast"; then
    candidate="Fast"
  elif [[ "$orig_mode" != "Trickle" ]] && has_mode "Trickle"; then
    candidate="Trickle"
  fi

  if [[ -n "$candidate" ]]; then
    log "dell-modes: ${orig_mode:-?} -> ${candidate}"
    if write_attr "$BAT/charge_types" "$candidate"; then
      sleep "$RESET_DWELL"
      if verify_charging "dell-modes toggle"; then
        if [[ "$LEAVE_WORKING_MODE" != "1" ]]; then
          write_attr "$BAT/charge_types" "$orig_mode" || true
        fi
        return 0
      fi
      write_attr "$BAT/charge_types" "$orig_mode" || true
    else
      log "dell-modes: failed to write charge_types"
    fi
  else
    log "dell-modes: no alternate mode available (active=${orig_mode:-?})"
  fi

  if has_mode "Custom"; then
    log "dell-modes: mode=Custom end=100 start=95"
    if write_attr "$BAT/charge_types" "Custom"; then
      write_attr "$BAT/charge_control_end_threshold" "100" ||
        log "dell-modes: warning: failed to set end threshold"
      write_attr "$BAT/charge_control_start_threshold" "95" ||
        log "dell-modes: warning: failed to set start threshold"
      sleep "$RESET_DWELL"
      if verify_charging "dell-modes custom"; then
        return 0
      fi
    else
      log "dell-modes: failed to set Custom mode"
    fi
  fi

  return 1
}

tier_suspend() {
  local rc
  if ! command -v rtcwake >/dev/null 2>&1; then
    log "suspend: rtcwake not found"
    return 1
  fi
  if [[ ! -w /sys/power/state ]]; then
    log "suspend: /sys/power/state is not writable"
    return 1
  fi

  log "suspend: suspending for ${SUSPEND_SECONDS}s to reinitialize the EC/PD state"
  sync
  rtcwake -m mem -s "$SUSPEND_SECONDS" >/dev/null 2>&1
  rc=$?
  if (( rc != 0 )); then
    log "suspend: rtcwake failed (rc=$rc)"
    return 1
  fi

  # Let the EC settle after resume before measuring the charge.
  sleep "$RESET_DWELL"
  verify_charging "suspend"
}

# Rebinding the ACPI EC driver re-runs its initialisation, which is the closest
# software equivalent to the Dell "drain flea power" reset. It is opt-in
# because a failed rebind loses battery/thermal monitoring until reboot.
tier_ec_rebind() {
  local dir="/sys/bus/acpi/drivers/ec"
  if [[ ! -e "$dir/$EC_DEVICE" ]]; then
    log "ec-rebind: $EC_DEVICE not bound to $dir"
    return 1
  fi
  log "ec-rebind: rebinding $EC_DEVICE (strong reset)"
  write_attr "$dir/unbind" "$EC_DEVICE" || {
    log "ec-rebind: unbind failed"
    return 1
  }
  sleep 1
  if ! write_attr "$dir/bind" "$EC_DEVICE"; then
    log "ec-rebind: bind failed; ACPI EC access is lost until reboot"
    notify "Battery recharge" "EC rebind FAILED - ACPI EC lost, reboot needed"
    return 1
  fi
  sleep "$RESET_DWELL"
  log "ec-rebind: EC rebound"
  verify_charging "ec-rebind"
}

# Last resort: a reboot re-runs the firmware's EC initialisation. Only used
# below a capacity floor so it cannot turn into a reboot loop.
tier_reboot() {
  local cap now ts=0
  cap=$(battery_capacity) || cap=100
  if (( cap > REBOOT_BELOW_CAPACITY )); then
    log "reboot: capacity ${cap}% is above the ${REBOOT_BELOW_CAPACITY}% floor"
    return 1
  fi
  now=$(date +%s)
  [[ -f "$LAST_REBOOT_FILE" ]] && read -r ts < "$LAST_REBOOT_FILE" || ts=0
  [[ "$ts" =~ ^[0-9]+$ ]] || ts=0
  if (( now - ts < REBOOT_COOLDOWN )); then
    log "reboot: rate limited ($(( now - ts ))s < ${REBOOT_COOLDOWN}s)"
    return 1
  fi
  printf '%s\n' "$now" > "$LAST_REBOOT_FILE" 2>/dev/null || true
  log "reboot: rebooting to re-initialize the EC (cap=${cap}%)"
  notify "Battery recharge" "Rebooting: EC stopped charging at ${cap}%"
  sync
  systemctl reboot || shutdown -r now || return 1
  return 0
}

# --- reset ladder -----------------------------------------------------------

# Order matters: the two ACPI rebinds are nearly free, then UCSI (the real
# "replug" analogue) and suspend get a chance before the heavier EC rebind.
# The Dell SMM mode toggles are last because they have never re-armed a stopped
# charger on this machine and each costs ~45s of verification; on a nearly empty
# pack that time is better spent reaching a tier that might work.
TIERS=(ac-rebind battery-rebind ucsi suspend ec-rebind dell-modes reboot)

tier_enabled() {
  case $1 in
    ac-rebind) [[ "$ENABLE_AC_REBIND" == "1" ]] ;;
    battery-rebind) [[ "$ENABLE_BATTERY_REBIND" == "1" ]] ;;
    ucsi) [[ "$ENABLE_UCSI_RESET" == "1" ]] ;;
    dell-modes) [[ "$ENABLE_DELL_MODES" == "1" ]] ;;
    suspend)
      [[ "$ENABLE_SUSPEND_RESET" == "1" ]] && (( failures >= SUSPEND_AFTER_FAILURES ))
      ;;
    ec-rebind) [[ "$ENABLE_EC_RESET" == "1" ]] ;;
    reboot) [[ "$ENABLE_REBOOT_RESET" == "1" ]] ;;
    *) return 1 ;;
  esac
}

run_tier() {
  case $1 in
    ac-rebind) tier_ac_rebind ;;
    battery-rebind) tier_battery_rebind ;;
    ucsi) tier_ucsi ;;
    dell-modes) tier_dell_modes ;;
    suspend) tier_suspend ;;
    ec-rebind) tier_ec_rebind ;;
    reboot) tier_reboot ;;
    *) return 1 ;;
  esac
}

# Try the tier that worked last time first, then the rest in order.
ordered_tiers() {
  local t out=()
  if [[ -n "$last_tier" ]]; then
    for t in "${TIERS[@]}"; do
      [[ "$t" == "$last_tier" ]] && out+=("$t")
    done
  fi
  for t in "${TIERS[@]}"; do
    [[ "$t" == "$last_tier" ]] || out+=("$t")
  done
  printf '%s\n' "${out[@]}"
}

attempt_reset() {
  local t
  log "reset: starting tier ladder (failures=$failures last_good=${last_tier:-none})"
  while read -r t; do
    [[ -n "$t" ]] || continue
    if ! tier_enabled "$t"; then
      log "reset: skipping disabled tier $t"
      continue
    fi
    if [[ "$DRY_RUN" == "1" ]]; then
      log "dry-run: would run tier $t"
      continue
    fi
    if run_tier "$t"; then
      last_tier=$t
      printf '%s\n' "$t" > "$LAST_TIER_FILE" 2>/dev/null || true
      log "reset: tier $t restarted charging"
      restore_original
      return 0
    fi
  done < <(ordered_tiers)
  restore_original
  return 1
}

# --- main loop --------------------------------------------------------------

restore_original

last_tier=$(cat "$LAST_TIER_FILE" 2>/dev/null || true)
samples=()
last_ac=""
attempts=0
failures=0
next_attempt=0
discharging_count=0
unreadable_count=0
charge_unreadable_count=0
last_charge=""
sustained_since=0
last_state_log=0

log "starting: bat=$BAT ac=$AC interval=${INTERVAL}s window=${WINDOW}s dry_run=$DRY_RUN ac_rebind=$ENABLE_AC_REBIND battery_rebind=$ENABLE_BATTERY_REBIND ucsi_reset=$ENABLE_UCSI_RESET dell_modes=$ENABLE_DELL_MODES suspend_reset=$ENABLE_SUSPEND_RESET ec_reset=$ENABLE_EC_RESET reboot_reset=$ENABLE_REBOOT_RESET last_good=${last_tier:-none}"
log "battery: mode=$(active_mode || printf '?') cap=$(battery_capacity || printf '?')% charge=$(battery_charge || printf '?') full=$(battery_full || printf '?') status=$(battery_status || printf '?')"
log "typec: $(typec_describe)"

while true; do
  ac=$(ac_online) || ac=""
  if [[ "$ac" != "1" ]]; then
    if [[ "$last_ac" != "0" ]]; then
      log "AC offline; resetting detection state"
    fi
    last_ac=0
    samples=()
    attempts=0
    failures=0
    next_attempt=0
    discharging_count=0
    unreadable_count=0
    charge_unreadable_count=0
    sustained_since=0
    sleep "$INTERVAL"
    continue
  fi

  if [[ "$last_ac" != "1" ]]; then
    log "AC online; monitoring battery"
  fi
  last_ac=1

  now=$(date +%s)
  charge=$(battery_charge) || charge=""
  if [[ -n "$charge" ]]; then
    last_charge=$charge
    charge_unreadable_count=0
    add_sample "$now" "$charge"
  else
    charge_unreadable_count=$(( charge_unreadable_count + 1 ))
  fi

  status=$(battery_status) || status=""
  if [[ "$status" == "Discharging" ]]; then
    discharging_count=$(( discharging_count + 1 ))
  else
    discharging_count=0
  fi

  current=$(battery_current) || current=""
  if [[ -n "$current" ]] && (( current > 0 )); then
    unreadable_count=0
  elif [[ -z "$current" ]]; then
    # The distinctive fault signature: the EC keeps reporting "Charging" but
    # current_now starts failing even though AC is online.
    unreadable_count=$(( unreadable_count + 1 ))
  else
    unreadable_count=0
  fi
  # current_now is only used as an early hint. The authoritative signal is the
  # charge_now trend below, because the EC has been seen reporting a healthy
  # positive current while the pack was in fact draining.

  cap=$(battery_capacity) || cap=100
  limit=$(charge_limit)
  at_limit=0
  (( cap >= limit - 1 )) && at_limit=1

  # After a successful reset, clear the exponential backoff once the pack has
  # been taking charge for a while.
  if (( sustained_since > 0 )) && (( now - sustained_since >= SUSTAINED_SECONDS )); then
    log "charging sustained for ${SUSTAINED_SECONDS}s; clearing failure backoff"
    failures=0
    sustained_since=0
  fi

  if (( now - last_state_log >= 300 )); then
    last_state_log=$now
    log "state: cap=${cap}% charge=${charge:-unreadable} current=${current:-unreadable} status=${status:-?} limit=${limit}% typec=$(typec_describe)"
  fi

  if (( now < next_attempt )); then
    sleep "$INTERVAL"
    continue
  fi

  trigger=0
  reason=""
  if (( at_limit == 0 )); then
    if (( discharging_count >= 2 )); then
      trigger=1
      reason="status Discharging x${discharging_count} while AC online"
    elif (( unreadable_count >= 2 )); then
      trigger=1
      reason="current_now unreadable x${unreadable_count} while AC online"
    elif (( charge_unreadable_count >= 3 )); then
      trigger=1
      reason="charge_now unreadable x${charge_unreadable_count}"
    elif rise=$(trend_rise); then
      need=$(min_rise_window)
      if (( rise < need )); then
        trigger=1
        reason="charge stalled over ${WINDOW}s (rise=${rise}uAh, need=${need}uAh)"
      fi
    fi
  fi

  if (( trigger )); then
    sustained_since=0
    log "trigger: $reason (cap=${cap}% charge=${charge:-unreadable} current=${current:-unreadable} status=${status:-?} typec=$(typec_describe))"
    [[ "$DRY_RUN" == "1" ]] ||
      notify "Battery recharge" "EC stopped charging (${reason}); attempting reset"

    if [[ "$DRY_RUN" != "1" ]]; then
      if attempt_reset; then
        log "reset: charging resumed"
        failures=0
        sustained_since=$now
        attempts=$(( attempts + 1 ))
        samples=()
        backoff=$COOLDOWN
        next_attempt=$(( now + backoff ))
        log "reset: next check in ${backoff}s"
        sleep "$INTERVAL"
        continue
      fi
      failures=$(( failures + 1 ))
      log "reset: all tiers failed (consecutive failures: $failures)"
      notify "Battery recharge" "All reset tiers failed (failure ${failures}, cap=${cap}%)"
    fi

    attempts=$(( attempts + 1 ))
    if (( MAX_ATTEMPTS > 0 && attempts >= MAX_ATTEMPTS )); then
      log "reset: reached MAX_ATTEMPTS=$MAX_ATTEMPTS for this AC session; waiting for a replug"
      next_attempt=$(( now + 86400 ))
    else
      backoff=$(( COOLDOWN * (1 << (failures > 4 ? 4 : failures)) ))
      (( backoff > MAX_COOLDOWN )) && backoff=$MAX_COOLDOWN
      next_attempt=$(( now + backoff ))
      log "reset: next attempt in ${backoff}s"
    fi
    samples=()
  fi

  sleep "$INTERVAL"
done
