import os
import signal
import time
from datetime import datetime, timezone

import psycopg2
from psycopg2 import Error, InterfaceError, OperationalError


RUNNING = True

DB_HOSTS = [host.strip() for host in os.getenv("DB_HOSTS", "postgres-master,postgres-slave").split(",") if host.strip()]
DB_PORT = int(os.getenv("DB_PORT", "5432"))
DB_NAME = os.getenv("DB_NAME", "appdb")
DB_USER = os.getenv("DB_USER", "postgres")
DB_PASSWORD = os.getenv("DB_PASSWORD", "postgres")
WRITE_INTERVAL_SECONDS = float(os.getenv("WRITE_INTERVAL_SECONDS", "1"))
RETRY_INITIAL_DELAY_SECONDS = float(os.getenv("RETRY_INITIAL_DELAY_SECONDS", "1"))
RETRY_MAX_DELAY_SECONDS = float(os.getenv("RETRY_MAX_DELAY_SECONDS", "5"))


def log(level, message):
    timestamp = datetime.now(timezone.utc).isoformat()
    print(f"{timestamp} [{level}] {message}", flush=True)


def handle_shutdown(signum, frame):
    del signum, frame

    global RUNNING
    RUNNING = False
    log("INFO", "shutdown requested")


signal.signal(signal.SIGINT, handle_shutdown)   
signal.signal(signal.SIGTERM, handle_shutdown)


def sleep_with_shutdown(seconds):
    deadline = time.monotonic() + seconds

    while RUNNING and time.monotonic() < deadline:
        time.sleep(min(0.2, deadline - time.monotonic()))


def ordered_hosts(failed_host=None):
    if failed_host and failed_host in DB_HOSTS:
        return [host for host in DB_HOSTS if host != failed_host] + [failed_host]

    return DB_HOSTS


def connect(host):
    return psycopg2.connect(
        host=host,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD,
        connect_timeout=3,
        application_name="writer",
    )


def is_master(connection):
    with connection.cursor() as cursor:
        cursor.execute("SELECT pg_is_in_recovery();")
        row = cursor.fetchone()

    return bool(row and row[0] is False)


def ensure_table_exists(connection):
    with connection.cursor() as cursor:
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS timestamp_log (
                id SERIAL PRIMARY KEY,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                source_node TEXT NOT NULL
            );
            """
        )


def insert_timestamp(connection, source_node):
    with connection.cursor() as cursor:
        cursor.execute(
            "INSERT INTO timestamp_log (source_node) VALUES (%s);",
            (source_node,),
        )


def close_connection(connection):
    if connection is None:
        return

    try:
        connection.close()
    except Exception:
        pass


def short_error(error):
    return str(error).strip().splitlines()[0]


def connect_to_master(failed_host=None):
    last_error = None

    for host in ordered_hosts(failed_host):
        try:
            connection = connect(host)
            connection.autocommit = True

            if not is_master(connection):
                close_connection(connection)
                continue

            ensure_table_exists(connection)
            log("INFO", f"connected to writable primary: {host}")
            return connection, host
        except (OperationalError, InterfaceError, Error) as error:
            last_error = error
            log("WARN", f"cannot use {host}: {short_error(error)}")

    if last_error is None:
        log("WARN", "no writable primary found in DB_HOSTS")
    return None, None


def main():
    connection = None
    current_host = None
    retry_delay = RETRY_INITIAL_DELAY_SECONDS

    while RUNNING:
        if connection is None:
            previous_host = current_host
            connection, current_host = connect_to_master(current_host)

            if connection is None:
                log("WARN", f"no writable primary found, retry in {retry_delay:.1f}s")
                sleep_with_shutdown(retry_delay)
                retry_delay = min(retry_delay * 2, RETRY_MAX_DELAY_SECONDS)
                continue

            if previous_host and previous_host != current_host:
                log("INFO", f"primary switched: {previous_host} -> {current_host}")

            retry_delay = RETRY_INITIAL_DELAY_SECONDS

        try:
            insert_timestamp(connection, current_host)
            log("INFO", f"insert ok: {current_host}")
            sleep_with_shutdown(WRITE_INTERVAL_SECONDS)
        except (OperationalError, InterfaceError, Error) as error:
            log("WARN", f"write failed on {current_host}: {short_error(error)}")
            close_connection(connection)
            connection = None
            sleep_with_shutdown(retry_delay)
            retry_delay = min(retry_delay * 2, RETRY_MAX_DELAY_SECONDS)

    close_connection(connection)
    log("INFO", "writer stopped")


if __name__ == "__main__":
    main()
