#!/usr/bin/env python3
import logging
import os
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

# ---------- Logging ----------
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s: %(message)s")
logger = logging.getLogger("nixostools/copy_down_dhis")


# ---------- Helpers ----------
def getenv(name, default=None, required=False, cast=str, choices=None):
    val = os.environ.get(name, default)
    if required and (val is None or (isinstance(val, str) and val.strip() == "")):
        logger.fatal("Missing required env var: %s", name)
        sys.exit(1)
    if cast is bool:
        if isinstance(val, str):
            v = val.strip().lower()
            if v in ("1", "true", "yes", "on"):
                return True
            if v in ("0", "false", "no", "off", "", None):
                return False
            logger.fatal("Invalid boolean for %s: %r", name, val)
            sys.exit(1)
        return bool(val)
    if cast is int and val is not None:
        try:
            val = int(val)
        except Exception:
            logger.fatal("Env var %s must be an integer; got %r", name, val)
            sys.exit(1)
    if choices and val not in choices:
        logger.fatal("Env var %s must be one of %s; got %r", name, choices, val)
        sys.exit(1)
    return val


def run_or_die(cmd, *, input_bytes=None, capture_output=False, env=None):
    logger.debug("Running: %s", " ".join(shlex.quote(c) for c in cmd))
    try:
        res = subprocess.run(
            cmd, input=input_bytes, capture_output=capture_output, env=env, check=True
        )
        return res
    except subprocess.CalledProcessError as e:
        if capture_output:
            logger.error(
                "Command failed: %s\nSTDOUT:\n%s\nSTDERR:\n%s",
                " ".join(cmd),
                e.stdout.decode(errors="ignore"),
                e.stderr.decode(errors="ignore"),
            )
        else:
            logger.error("Command failed: %s (exit %s)", " ".join(cmd), e.returncode)
        raise


def check_requirements():
    for tool in ["docker", "ssh"]:
        try:
            run_or_die(
                [tool, "-V" if tool == "ssh" else "--version"], capture_output=True
            )
        except Exception:
            logger.fatal("Required tool not found or not working: %s", tool)
            sys.exit(2)


def ssh_base(ssh_user, ssh_host, ssh_port, use_relay, relay_host):
    base = [
        "ssh",
        "-vvv",  # enable detailed SSH debugging
        "-p",
        str(ssh_port),
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "UserKnownHostsFile=/dev/null",
        "-o",
        "IdentitiesOnly=yes",
    ]
    if use_relay:
        base += ["-o", f"ProxyJump={relay_host}"]
    base += [f"{ssh_user}@{ssh_host}"]
    return base


def build_remote_pg_dump_cmd(
    remote_container,
    remote_db,
    remote_user,
    remote_port,
    remote_password,
    dump_format,  # "custom format" or "plain SQL"
    include_create,  # bool -> add -C
    extra_dump_args,
):
    extra = shlex.split(extra_dump_args) if extra_dump_args else []
    if dump_format == "custom":
        dump_args = [
            "pg_dump",
            "-h",
            "localhost",
            "-p",
            str(remote_port),
            "-U",
            remote_user,
            "-d",
            remote_db,
            "-Fc",
        ]
        if include_create:
            dump_args.append("-C")
        dump_args += extra
        restore_hint = "pg_restore"
    else:
        # Plain SQL
        dump_args = [
            "pg_dump",
            "-h",
            "localhost",
            "-p",
            str(remote_port),
            "-U",
            remote_user,
            "-d",
            remote_db,
            "-Fp",
            "-f",
            "-",
        ] + extra
        if include_create:
            dump_args.append("-C")
        restore_hint = "psql"

    docker_cmd = [
        "docker",
        "exec",
        "-e",
        f"PGPASSWORD={remote_password or ''}",
        "-i",
        remote_container,
        *dump_args,
    ]
    remote = " ".join(shlex.quote(t) for t in docker_cmd)
    logger.info("Remote dump will stream via %s.", restore_hint)
    return remote


def sanitize_psql_extras(extra: str | None) -> list[str]:
    tokens = shlex.split(extra) if extra else []
    fixed: list[str] = []
    i = 0
    found_on_error_stop = False

    while i < len(tokens):
        t = tokens[i]
        if t.startswith("--set="):
            kv = t.split("=", 1)[1]
            if kv:
                fixed += ["-v", kv]
                if kv.upper().startswith("ON_ERROR_STOP="):
                    found_on_error_stop = True
            # if empty (--set=) -> drop
            i += 1
            continue

        if t in ("--set", "-v"):
            if (
                i + 1 < len(tokens)
                and not tokens[i + 1].startswith("-")
                and tokens[i + 1]
            ):
                kv = tokens[i + 1]
                fixed += ["-v", kv]
                if kv.upper().startswith("ON_ERROR_STOP="):
                    found_on_error_stop = True
                i += 2
            else:
                i += 1
            continue

        fixed.append(t)
        i += 1

    # Always ensure ON_ERROR_STOP=1
    if not found_on_error_stop:
        fixed += ["-v", "ON_ERROR_STOP=1"]

    return fixed


def build_local_pg_restore_cmd(
    local_container,
    local_db,
    local_user,
    local_port,
    local_password,
    dump_format,  # "custom" or "plain"
    restore_clean,  # bool (pg_restore only)
    local_psql_extra_args,  # e.g. "--set ON_ERROR_STOP=1"
    include_create,  # bool: if True (plain), connect to postgres
):
    if dump_format == "custom":
        # Connect to postgres if dump has -C (pg_restore will create DB). Otherwise to target DB.
        target_db = "postgres" if include_create else local_db
        restore_cmd = [
            "docker",
            "exec",
            "-e",
            f"PGPASSWORD={local_password or ''}",
            "-i",
            local_container,
            "pg_restore",
            "-h",
            "localhost",
            "-p",
            str(local_port),
            "-U",
            local_user,
            "-d",
            target_db,
        ]
        if restore_clean:
            restore_cmd += ["--clean", "--if-exists"]
        # Read from stdin implicitly (omit "-")
        return restore_cmd
    else:
        extra_psql = sanitize_psql_extras(local_psql_extra_args)
        target_db = "postgres" if include_create else local_db
        restore_cmd = [
            "docker",
            "exec",
            "-e",
            f"PGPASSWORD={local_password or ''}",
            "-i",
            local_container,
            "psql",
            "-h",
            "localhost",
            "-p",
            str(local_port),
            "-U",
            local_user,
            "-d",
            target_db,
            *extra_psql,
        ]
        return restore_cmd


def drop_and_create_db(
    *,
    local_container,
    local_db,
    local_user,
    local_port,
    local_password,
    create_after_drop: bool,
    log_path: Path,
):
    """
    Drop DB (force, if exists). Optionally create it again.
    Logs stdout+stderr to log_path (append).
    """
    drop_cmd = [
        "docker",
        "exec",
        "-e",
        f"PGPASSWORD={local_password or ''}",
        "-i",
        local_container,
        "dropdb",
        "-h",
        "localhost",
        "-p",
        str(local_port),
        "-U",
        local_user,
        "--force",
        "--if-exists",
        local_db,
    ]
    create_cmd = [
        "docker",
        "exec",
        "-e",
        f"PGPASSWORD={local_password or ''}",
        "-i",
        local_container,
        "createdb",
        "-h",
        "localhost",
        "-p",
        str(local_port),
        "-U",
        local_user,
        local_db,
    ]

    logger.info("Dropping database %r (if exists)...", local_db)
    with log_path.open("ab") as log_file:
        res_drop = subprocess.run(drop_cmd, stdout=log_file, stderr=subprocess.STDOUT)
    if res_drop.returncode == 0:
        logger.info("dropdb completed (or DB did not exist).")
    else:
        logger.warning(
            "dropdb returned code %s; see log: %s", res_drop.returncode, log_path
        )

    if create_after_drop:
        logger.info("Creating database %r...", local_db)
        with log_path.open("ab") as log_file:
            res_create = subprocess.run(
                create_cmd, stdout=log_file, stderr=subprocess.STDOUT
            )
        if res_create.returncode != 0:
            logger.error(
                "createdb failed (exit %s). See log: %s",
                res_create.returncode,
                log_path,
            )
            sys.exit(res_create.returncode)
        logger.info("createdb completed.")


def stop_docker_container(container_name):
    """Stop a Docker container safely."""
    cmd = ["docker", "stop", container_name]
    try:
        run_or_die(cmd)
        logger.info("Docker container '%s' stopped successfully.", container_name)
    except Exception:
        logger.error("Failed to stop Docker container '%s'.", container_name)
        sys.exit(1)


def start_docker_container(container_name):
    """Start a Docker container safely."""
    cmd = ["docker", "start", container_name]
    try:
        run_or_die(cmd)
        logger.info("Docker container '%s' started successfully.", container_name)
    except Exception:
        logger.error("Failed to start Docker container '%s'.", container_name)


# ---------- Main ----------
def main():
    check_requirements()

    # SSH & relay
    host = getenv("HOST", required=True)
    ssh_user = getenv("SSH_USER", required=True)
    ssh_host = getenv("SSH_HOST", default=host)  # can override if using a relay
    ssh_port = getenv("SSH_PORT", default="22", cast=int)
    use_relay = getenv("USE_RELAY", default="false", cast=bool)
    relay_host = getenv("SSH_RELAY_HOST", default="tunneller@sshrelay.ocb.msf.org:443")

    # Remote DB (docker)
    remote_container = getenv("REMOTE_CONTAINER", required=True)
    remote_db = getenv("REMOTE_DB", required=True)
    remote_user = getenv("REMOTE_USER", default="postgres")
    remote_port = getenv("REMOTE_PORT", default="5432", cast=int)
    remote_password = getenv("REMOTE_PGPASSWORD", default=None)

    # Local DB (docker)
    local_container = getenv("LOCAL_DB_CONTAINER", required=True)
    local_web_container = getenv("LOCAL_WEB_CONTAINER", default=None)
    local_db = getenv("LOCAL_DB", required=True)
    local_user = getenv("LOCAL_USER", default="postgres")
    local_port = getenv("LOCAL_PORT", default="5432", cast=int)
    local_password = getenv("LOCAL_PGPASSWORD", default=None)

    # Dump/restore behavior
    dump_format = getenv("FORMAT", default="custom", choices=("custom", "plain"))
    include_create = not getenv(
        "NO_CREATE", default="false", cast=bool
    )  # if True => add -C
    restore_clean = getenv("RESTORE_CLEAN", default="false", cast=bool)  # custom only
    extra_dump_args = getenv("REMOTE_EXTRA_DUMP_ARGS", default="")
    local_psql_extra_args = getenv(
        "LOCAL_PSQL_EXTRA_ARGS", default="--set=ON_ERROR_STOP=0"
    )
    output_path = getenv("OUTPUT", default=None)

    if dump_format == "plain" and restore_clean:
        logger.warning("--RESTORE_CLEAN is ignored with plain format (psql).")

    # Prepare dump file
    if output_path:
        dump_path = Path(output_path).expanduser().resolve()
        dump_path.parent.mkdir(parents=True, exist_ok=True)
        tmp_ctx = None
    else:
        tmp_ctx = tempfile.NamedTemporaryFile(
            prefix="pg_dump_",
            suffix=(".dump" if dump_format == "custom" else ".sql"),
            delete=False,
        )
        dump_path = Path(tmp_ctx.name)
        tmp_ctx.close()

    try:
        logger.info("Dump file: %s", dump_path)

        # Build & run remote dump over ssh -> local file
        remote_cmd = build_remote_pg_dump_cmd(
            remote_container=remote_container,
            remote_db=remote_db,
            remote_user=remote_user,
            remote_port=remote_port,
            remote_password=remote_password,
            dump_format=dump_format,
            include_create=include_create,
            extra_dump_args=extra_dump_args,
        )
        ssh_cmd = ssh_base(ssh_user, ssh_host, ssh_port, use_relay, relay_host) + [
            remote_cmd
        ]
        logger.info("Starting remote dump and streaming to local file...")
        logger.debug("SSH command: %s", " ".join(shlex.quote(c) for c in ssh_cmd))

        with dump_path.open("wb") as f:
            proc = subprocess.Popen(ssh_cmd, stdout=f, stderr=subprocess.PIPE)
            _, stderr = proc.communicate()
            if proc.returncode != 0:
                logger.error("SSH/remote dump failed with code %s", proc.returncode)
                if stderr:
                    logger.error("Remote stderr:\n%s", stderr.decode(errors="ignore"))
                sys.exit(proc.returncode)

        if dump_path.stat().st_size == 0:
            logger.fatal("Dump file is empty; aborting.")
            sys.exit(3)

        logger.info(
            "Dump completed successfully (size: %.2f MB).",
            dump_path.stat().st_size / (1024 * 1024),
        )

        # Prepare log path (reuse for drop/create and restore)
        log_path = dump_path.with_suffix(".restore.log")
        logger.info("Logs will be written to %s", log_path)

        # If web container is specified, stop it before restore
        if local_web_container:
            logger.info(
                "Stopping local web container '%s' before restore...",
                local_web_container,
            )
            stop_docker_container(local_web_container)

        # ---- Drop/Create strategy before restore ----
        if dump_format == "plain":
            # For plain SQL: always drop & create before restore
            drop_and_create_db(
                local_container=local_container,
                local_db=local_db,
                local_user=local_user,
                local_port=local_port,
                local_password=local_password,
                create_after_drop=not include_create,
                log_path=log_path,
            )
        else:
            # For custom format:
            if include_create:
                # Drop only, pg_restore -C will create it
                drop_and_create_db(
                    local_container=local_container,
                    local_db=local_db,
                    local_user=local_user,
                    local_port=local_port,
                    local_password=local_password,
                    create_after_drop=False,
                    log_path=log_path,
                )
            else:
                # Drop & create Database Like we do when migrating existing DHIS2 DBs
                drop_and_create_db(
                    local_container=local_container,
                    local_db=local_db,
                    local_user=local_user,
                    local_port=local_port,
                    local_password=local_password,
                    create_after_drop=True,
                    log_path=log_path,
                )

        # ---- Restore locally ----
        logger.info("Starting local restore into container '%s'...", local_container)
        local_restore_cmd = build_local_pg_restore_cmd(
            local_container=local_container,
            local_db=local_db,
            local_user=local_user,
            local_port=local_port,
            local_password=local_password,
            dump_format=dump_format,
            restore_clean=restore_clean,
            local_psql_extra_args=local_psql_extra_args,
            include_create=include_create,
        )

        with dump_path.open("rb") as dump_file, log_path.open("ab") as log_file:
            logger.debug(
                "Restore cmd: %s", " ".join(shlex.quote(x) for x in local_restore_cmd)
            )
            result = subprocess.run(
                local_restore_cmd,
                stdin=dump_file,
                stdout=log_file,
                stderr=subprocess.STDOUT,
            )

        if result.returncode != 0:
            logger.error(
                "Restore failed (exit code %d). See log: %s",
                result.returncode,
                log_path,
            )
            sys.exit(result.returncode)
        else:
            # If web container was stopped, start it again
            if local_web_container:
                logger.info(
                    "Starting local web container '%s' after restore...",
                    local_web_container,
                )
                start_docker_container(local_web_container)
            logger.info("Restore completed successfully. Log saved to %s", log_path)

    finally:
        if output_path:
            logger.info("Leaving dump file at %s (user-specified OUTPUT).", dump_path)
        else:
            try:
                dump_path.unlink(missing_ok=True)
                logger.info("Temporary dump file removed.")
            except Exception:
                logger.warning("Could not remove temporary dump file: %s", dump_path)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        logger.error("Interrupted by user.")
        sys.exit(130)
