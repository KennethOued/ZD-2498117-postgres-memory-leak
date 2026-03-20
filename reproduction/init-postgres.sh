#!/bin/bash
set -e

DATABASES=(
  "feeds_statistics"
  "plugins_auth"
  "plugins_config"
  "users_profiles"
  "orders_processing"
  "payment_gateway"
  "notifications_svc"
  "analytics_events"
  "inventory_mgmt"
  "session_store"
)

for db in "${DATABASES[@]}"; do
  echo "Creating database: $db"
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
    CREATE DATABASE "$db";
EOSQL
done

for db in "${DATABASES[@]}"; do
  echo "Populating database: $db with 300 tables..."
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$db" <<-'EOSQL'

    CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

    -- Create datadog user with monitoring permissions
    CREATE USER datadog WITH PASSWORD 'datadog';
    GRANT pg_monitor TO datadog;
    GRANT SELECT ON pg_stat_activity TO datadog;

    -- Create 300 tables across public schema to simulate relation_regex: .* with max_relations: 300
    DO $$
    DECLARE
      i INTEGER;
    BEGIN
      FOR i IN 1..300 LOOP
        EXECUTE format(
          'CREATE TABLE IF NOT EXISTS public.tbl_%s (
            id BIGSERIAL PRIMARY KEY,
            data TEXT DEFAULT md5(random()::text),
            status INTEGER DEFAULT floor(random()*10),
            created_at TIMESTAMPTZ DEFAULT now(),
            updated_at TIMESTAMPTZ DEFAULT now()
          )', lpad(i::text, 4, '0')
        );

        -- Insert some rows so relation stats are populated
        EXECUTE format(
          'INSERT INTO public.tbl_%s (data, status) SELECT md5(random()::text), floor(random()*10)::int FROM generate_series(1, 50)',
          lpad(i::text, 4, '0')
        );

        -- Create an index on each table to add more relation objects
        EXECUTE format(
          'CREATE INDEX IF NOT EXISTS idx_tbl_%s_status ON public.tbl_%s (status)',
          lpad(i::text, 4, '0'), lpad(i::text, 4, '0')
        );
      END LOOP;
    END $$;

    -- Create replication slot for custom query simulation
    -- (skip if already exists)
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = 'test_slot') THEN
        PERFORM pg_create_logical_replication_slot('test_slot', 'pgoutput');
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'Could not create replication slot: %', SQLERRM;
    END $$;

    ANALYZE;
EOSQL
  echo "  -> $db populated."
done

echo "=== All databases initialized ==="
