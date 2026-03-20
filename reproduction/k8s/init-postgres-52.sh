#!/bin/bash
set -e

DATABASES=(
  "feeds_statistics" "plugins_auth" "plugins_config" "users_profiles"
  "orders_processing" "payment_gateway" "notifications_svc" "analytics_events"
  "inventory_mgmt" "session_store" "auth_service" "billing_core"
  "catalog_products" "chat_messages" "config_store" "content_delivery"
  "crm_contacts" "data_pipeline" "device_registry" "docs_storage"
  "email_templates" "feature_flags" "file_uploads" "fraud_detection"
  "geo_location" "graph_social" "health_checks" "identity_provider"
  "image_processing" "job_scheduler" "key_vault" "logging_service"
  "media_transcoder" "metrics_aggregator" "notification_prefs" "oauth_tokens"
  "onboarding_flow" "payment_ledger" "permissions_acl" "pricing_engine"
  "queue_manager" "rate_limiter" "recommendation_engine" "referral_program"
  "reporting_dash" "search_index" "security_audit" "shipping_tracker"
  "subscription_mgmt" "tax_calculator" "usage_metering" "webhook_dispatcher"
)

echo "=== Creating ${#DATABASES[@]} databases ==="

for db in "${DATABASES[@]}"; do
  echo "Creating database: $db"
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
    CREATE DATABASE "$db";
EOSQL
done

echo "=== Creating datadog user ==="
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
  CREATE USER datadog WITH PASSWORD 'datadog';
EOSQL

for db in "${DATABASES[@]}"; do
  echo "Populating: $db (300 tables)..."
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$db" <<-'EOSQL'
    CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
    GRANT pg_monitor TO datadog;
    GRANT SELECT ON pg_stat_activity TO datadog;

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
        EXECUTE format(
          'INSERT INTO public.tbl_%s (data, status) SELECT md5(random()::text), floor(random()*10)::int FROM generate_series(1, 50)',
          lpad(i::text, 4, '0')
        );
        EXECUTE format(
          'CREATE INDEX IF NOT EXISTS idx_tbl_%s_status ON public.tbl_%s (status)',
          lpad(i::text, 4, '0'), lpad(i::text, 4, '0')
        );
      END LOOP;
    END $$;
    ANALYZE;
EOSQL
  echo "  -> $db done"
done

echo "=== All ${#DATABASES[@]} databases initialized ==="
