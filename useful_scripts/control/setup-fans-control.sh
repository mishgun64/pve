#!/bin/bash
#
# setup-fans-control.sh
#
# Recreates the fan-control state on the host "control" (192.168.2.201):
#   - loads the it87 driver for the ITE IT8783F SuperIO chip (autoload at boot)
#   - writes /usr/local/sbin/fan-ctl.sh (fan curve daemon)
#   - installs + enables fan-ctl.service (systemd)
#
# Resulting steady state:
#   pwm1 -> fan1 = CPU fan (4-pin)   : pwm 0  => its own minimum ~866 RPM
#   pwm2 -> fan2 = case fan (3-pin)  : pwm 30 => ~870 RPM (below ~25 it stalls)
#   pwm3 -> fan3 = not connected
#
# CPU safety curve inside the daemon: <=55 C -> 0, >=75 C -> 255.
# Measured under 100% load on both cores: 47 C peak, critical is 102 C.
#
# Usage: sudo ./setup-fans-control.sh
#
set -euo pipefail

HW_IT87_NAME="it8783"
HW_CORE_NAME="coretemp"
SCRIPT_PATH="/usr/local/sbin/fan-ctl.sh"
SERVICE_PATH="/etc/systemd/system/fan-ctl.service"
MODULES_CONF="/etc/modules-load.d/it87.conf"

log()  { printf '[setup-fans] %s\n' "$*"; }
fail() { printf '[setup-fans] ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight ---
[ "$(id -u)" -eq 0 ] || fail "must run as root (use sudo)"

find_hwmon() {
    local want=$1 d
    for d in /sys/class/hwmon/hwmon*; do
        [ -r "$d/name" ] || continue
        if [ "$(cat "$d/name" 2>/dev/null)" = "$want" ]; then
            printf '%s\n' "$d"
            return 0
        fi
    done
    return 1
}

# ------------------------------------------------------------------- driver ---
log "loading it87 / coretemp kernel modules"
modprobe coretemp 2>/dev/null || true
if ! modprobe it87; then
    log "modprobe it87 failed, device may need an explicit address; giving up"
    fail "cannot load it87 (check 'sensors-detect' output for the chip address)"
fi

if ! find_hwmon "$HW_IT87_NAME" >/dev/null; then
    sleep 1
    find_hwmon "$HW_IT87_NAME" >/dev/null \
        || fail "hwmon '$HW_IT87_NAME' not present after modprobe it87"
fi

mkdir -p /etc/modules-load.d
cat > "$MODULES_CONF" <<'EOF'
it87
coretemp
EOF
log "wrote $MODULES_CONF (autoload at boot)"

# ------------------------------------------------------------- fan daemon -----
log "writing $SCRIPT_PATH"
cat > "$SCRIPT_PATH" <<'SCRIPT'
#!/bin/bash
# Fan control for ITE IT8783F (SuperIO) on this board.
#   pwm1 -> fan1 = CPU fan (4-pin)
#   pwm2 -> fan2 = case fan (3-pin, needs >= ~30/255 to keep spinning)
#   pwm3 -> fan3 = unused
#
# CPU fan runs at the fan's own minimum (~865 RPM) and only ramps up if the
# CPU package temperature rises. Case fan is held at a low but reliable speed
# so the 3-pin motor never stalls.

set -u

INTERVAL=10

# 3-pin case fan: below ~25/255 it stalls, 30/255 gives ~840 RPM.
CASE_PWM=30

# CPU fan curve (package temp in milli-Celsius -> pwm 0..255)
LO_T=55000
HI_T=75000
PWM_LOW=0
PWM_HIGH=255

find_hwmon() {
    local want=$1 d
    for d in /sys/class/hwmon/hwmon*; do
        [ -r "$d/name" ] || continue
        if [ "$(cat "$d/name" 2>/dev/null)" = "$want" ]; then
            printf '%s\n' "$d"
            return 0
        fi
    done
    return 1
}

write_attr() {
    local path=$1 value=$2
    [ -w "$path" ] || return 0
    printf '%s\n' "$value" > "$path" 2>/dev/null || true
}

last_it87=""

while :; do
    it87=$(find_hwmon it8783) || it87=""
    core=$(find_hwmon coretemp) || core=""

    if [ -n "$it87" ]; then
        if [ "$it87" != "$last_it87" ]; then
            write_attr "$it87/pwm1_enable" 1
            write_attr "$it87/pwm2_enable" 1
            last_it87=$it87
        fi

        pwm1=$PWM_LOW
        if [ -n "$core" ] && [ -r "$core/temp1_input" ]; then
            t=$(cat "$core/temp1_input" 2>/dev/null) || t=""
            case "$t" in
                ''|*[!0-9]*) t="" ;;
            esac
            if [ -n "$t" ]; then
                if [ "$t" -le "$LO_T" ]; then
                    pwm1=$PWM_LOW
                elif [ "$t" -ge "$HI_T" ]; then
                    pwm1=$PWM_HIGH
                else
                    pwm1=$(( PWM_LOW + (t - LO_T) * (PWM_HIGH - PWM_LOW) / (HI_T - LO_T) ))
                fi
            fi
        fi

        write_attr "$it87/pwm1" "$pwm1"
        write_attr "$it87/pwm2" "$CASE_PWM"
    fi

    sleep "$INTERVAL"
done
SCRIPT
chmod 755 "$SCRIPT_PATH"
bash -n "$SCRIPT_PATH" || fail "syntax error in $SCRIPT_PATH"

# ------------------------------------------------------------------ service ---
log "writing $SERVICE_PATH"
cat > "$SERVICE_PATH" <<'EOF'
[Unit]
Description=IT8783 fan control (CPU fan at minimum, case fan low)
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/fan-ctl.sh
Restart=always
RestartSec=5
Nice=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable fan-ctl.service >/dev/null 2>&1 || true
systemctl restart fan-ctl.service
log "fan-ctl.service enabled and (re)started"

# ------------------------------------------------------------------- verify ---
log "waiting for the daemon to apply the pwm values"
applied=0
for _ in $(seq 1 15); do
    sleep 1
    H=$(find_hwmon "$HW_IT87_NAME" || true)
    [ -n "$H" ] || continue
    en1=$(cat "$H/pwm1_enable" 2>/dev/null || echo "")
    en2=$(cat "$H/pwm2_enable" 2>/dev/null || echo "")
    if [ "$en1" = "1" ] && [ "$en2" = "1" ]; then
        applied=1
        break
    fi
done
[ "$applied" -eq 1 ] || fail "daemon did not switch pwm1/pwm2 into manual mode"

H=$(find_hwmon "$HW_IT87_NAME")
CORE=$(find_hwmon "$HW_CORE_NAME" || true)

echo
log "final state:"
printf '  %-22s %s\n' "fan1 (CPU)"   "$(cat "$H/fan1_input" 2>/dev/null) RPM, pwm1=$(cat "$H/pwm1" 2>/dev/null) enable=$(cat "$H/pwm1_enable" 2>/dev/null)"
printf '  %-22s %s\n' "fan2 (case)"  "$(cat "$H/fan2_input" 2>/dev/null) RPM, pwm2=$(cat "$H/pwm2" 2>/dev/null) enable=$(cat "$H/pwm2_enable" 2>/dev/null)"
printf '  %-22s %s\n' "fan3 (unused)" "$(cat "$H/fan3_input" 2>/dev/null) RPM, pwm3=$(cat "$H/pwm3" 2>/dev/null) enable=$(cat "$H/pwm3_enable" 2>/dev/null)"
if [ -n "$CORE" ]; then
    printf '  %-22s %s C\n' "CPU package temp" "$(( $(cat "$CORE/temp1_input") / 1000 ))"
fi
printf '  %-22s %s\n' "service" "$(systemctl is-active fan-ctl.service) / $(systemctl is-enabled fan-ctl.service)"

echo
log "done. useful checks: sensors | systemctl status fan-ctl | journalctl -u fan-ctl -n 20"
