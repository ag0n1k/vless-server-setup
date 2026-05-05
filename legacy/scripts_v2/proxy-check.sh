#!/bin/bash
PORT=7895
HOST="0.0.0.0"

if ! ss -tlnp | grep -q ":${PORT}"; then
    logger -t tproxy-watchdog "Port ${PORT} not listening, restarting sing-box"
    systemctl restart sing-box
fi
