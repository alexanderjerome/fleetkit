# Stale-lockfile cleanup for every host running services.postgresql.
#
# After an ungraceful shutdown (host crash, OOM kill, LXC stop without
# `pg_ctl stop`), `postmaster.pid` outlives the postmaster. The kernel
# eventually reassigns that PID to some other process — `postgres_exporter`
# is a frequent culprit because it shares the postgres unit's restart
# cohort and tends to grab the next available PID. Postgres' lockfile
# preflight checks `kill(pid, 0)`, sees the PID is alive, treats the
# lock as held, and refuses to start. systemd's restart-loop rate
# limiter (StartLimitInterval) then trips and the service stays failed
# until manual `rm postmaster.pid`.
#
# This module adds a preStart hook (lib.mkBefore so it runs before the
# upstream initdb block) that detects the stale-PID case by reading
# /proc/<pid>/comm and removing the lockfile only when the PID belongs
# to something that isn't postgres. If a real postmaster IS holding the
# lock the file is left alone — that's a genuine conflict and should
# fail loudly.
#
# Triggered by any module that sets services.postgresql.enable, so
# infra.data.postgresql / infra.analytics-db / infra.timescale-db / upstream
# nix-bitcoin postgres all benefit.
{ config, lib, ... }:
{
  config = lib.mkIf config.services.postgresql.enable {
    systemd.services.postgresql.preStart = lib.mkBefore ''
      PIDFILE="${config.services.postgresql.dataDir}/postmaster.pid"
      if [ -f "$PIDFILE" ]; then
        PID=$(head -1 "$PIDFILE" 2>/dev/null || true)
        if [ -n "$PID" ]; then
          if [ -d "/proc/$PID" ]; then
            COMM=$(cat "/proc/$PID/comm" 2>/dev/null || echo "")
            if [ "$COMM" != "postgres" ] && [ "$COMM" != "postmaster" ]; then
              echo "postgresql preStart: stale postmaster.pid — PID $PID is '$COMM' (not postgres), removing lockfile" >&2
              rm -f "$PIDFILE"
            else
              echo "postgresql preStart: PID $PID is live postgres ($COMM), leaving lockfile alone" >&2
            fi
          else
            echo "postgresql preStart: stale postmaster.pid — PID $PID does not exist, removing lockfile" >&2
            rm -f "$PIDFILE"
          fi
        fi
      fi
    '';
  };
}
