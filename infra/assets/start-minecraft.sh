#!/bin/bash
# start-minecraft.sh - Minecraft server FIFO wrapper.
#
# This script is called by minecraft.service as ExecStart.
#
# Design:
#   1. Creates a named pipe (FIFO) at /run/minecraft/stdin.
#      The directory /run/minecraft is created by systemd via RuntimeDirectory=.
#   2. Opens the FIFO read/write on fd 3 with "exec 3<>/run/minecraft/stdin".
#      Keeping a permanent writer (fd 3) open prevents the FIFO from delivering
#      EOF to the server's stdin when individual command writers (ExecStop,
#      backup.sh) close their end. Without this, the first "echo cmd > fifo"
#      would cause the server to see EOF and may cause it to exit.
#   3. Replaces this wrapper process with the JVM using "exec java ... <&3".
#      Because exec replaces the process, systemd tracks the JVM directly.
#      Restart=on-failure and exit-code monitoring are fully reliable.
#
# Console commands (from ExecStop, backup.sh, or manually):
#   echo "say Hello" > /run/minecraft/stdin
#   echo "whitelist add PlayerName" > /run/minecraft/stdin

set -euo pipefail

FIFO="/run/minecraft/stdin"
MINECRAFT_DIR="/opt/minecraft"
JAR="${MINECRAFT_DIR}/server.jar"

# RuntimeDirectory=minecraft ensures /run/minecraft exists and is owned
# by the minecraft user before this script runs.
if [[ ! -d /run/minecraft ]]; then
  echo "ERROR: /run/minecraft does not exist. Is RuntimeDirectory=minecraft set?" >&2
  exit 1
fi

# Create the FIFO. Fail if it already exists as a regular file.
if [[ -e "$FIFO" && ! -p "$FIFO" ]]; then
  echo "ERROR: $FIFO exists but is not a FIFO." >&2
  exit 1
fi

if [[ ! -p "$FIFO" ]]; then
  mkfifo "$FIFO"
fi

# Open the FIFO read/write on fd 3. This is the permanent writer that prevents
# EOF on the server's stdin between individual command writes.
exec 3<>"$FIFO"

# Replace this process with the JVM. Systemd now tracks the JVM directly.
# stdin is redirected from fd 3 (the FIFO).
# stdout/stderr are handled by StandardOutput/StandardError in the unit file.
exec java \
  -Xms"${JAVA_XMS}" \
  -Xmx"${JAVA_XMX}" \
  -XX:+UseG1GC \
  -XX:+ParallelRefProcEnabled \
  -XX:MaxGCPauseMillis=200 \
  -jar "${JAR}" \
  --nogui \
  <&3
