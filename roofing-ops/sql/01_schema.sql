-- Roofing operations sample: schema
-- Everything the Retool app reads goes through functions in schema "api".
-- The Retool resource connects as role retool_app, which can EXECUTE those functions
-- and nothing else: no direct SELECT on any table.
DROP SCHEMA IF EXISTS core CASCADE; DROP SCHEMA IF EXISTS api CASCADE;
CREATE SCHEMA core; CREATE SCHEMA api;

CREATE TABLE core.regions (id serial PRIMARY KEY, name text NOT NULL UNIQUE);
CREATE TABLE core.crews   (id serial PRIMARY KEY, name text NOT NULL, region_id int NOT NULL REFERENCES core.regions);

CREATE TYPE core.app_role AS ENUM ('admin', 'ops_manager', 'estimator', 'crew_lead', 'claims');
CREATE TABLE core.app_users (
  email      text PRIMARY KEY CHECK (email = lower(email)),
  role       core.app_role NOT NULL,
  region_id  int REFERENCES core.regions,      -- ops_manager, estimator
  crew_id    int REFERENCES core.crews,        -- crew_lead
  active     boolean NOT NULL DEFAULT true
);

CREATE TABLE core.customers (
  id serial PRIMARY KEY, full_name text NOT NULL, phone text, email text, address text NOT NULL
);

CREATE TYPE core.job_status AS ENUM ('lead', 'inspected', 'estimated', 'sold', 'scheduled', 'in_progress', 'complete', 'lost');
CREATE TABLE core.jobs (
  id            bigserial PRIMARY KEY,
  customer_id   int NOT NULL REFERENCES core.customers,
  region_id     int NOT NULL REFERENCES core.regions,
  crew_id       int REFERENCES core.crews,
  estimator     text REFERENCES core.app_users(email),
  status        core.job_status NOT NULL DEFAULT 'lead',
  roof_type     text NOT NULL,                  -- shingle, metal, tile, flat
  squares       numeric(6,1),                   -- 1 square = 100 sq ft
  contract_usd  numeric(10,2),
  insurance_job boolean NOT NULL DEFAULT false,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
-- One index per access scope, each in the list's sort order, so a page is an index range read.
CREATE INDEX jobs_region_created ON core.jobs (region_id, created_at DESC, id DESC);
CREATE INDEX jobs_crew_created   ON core.jobs (crew_id, created_at DESC, id DESC) WHERE crew_id IS NOT NULL;
CREATE INDEX jobs_insurance_created ON core.jobs (created_at DESC, id DESC) WHERE insurance_job;
CREATE INDEX jobs_created        ON core.jobs (created_at DESC, id DESC);

-- Regulated data: insurance claim details. Only admin and claims can read policy/claim numbers.
CREATE TABLE core.claims (
  job_id        bigint PRIMARY KEY REFERENCES core.jobs ON DELETE CASCADE,
  carrier       text NOT NULL,
  claim_number  text NOT NULL,
  policy_number text NOT NULL,
  adjuster      text,
  storm_date    date
);

CREATE TABLE core.inspections (
  id            bigserial PRIMARY KEY,
  job_id        bigint NOT NULL REFERENCES core.jobs ON DELETE CASCADE,
  external_id   text NOT NULL UNIQUE,           -- idempotency key from the inspection app webhook
  inspected_at  timestamptz NOT NULL,
  hail_hits     int, wind_damage boolean, notes text
);

CREATE TABLE core.audit_log (
  id bigserial PRIMARY KEY, at timestamptz NOT NULL DEFAULT now(),
  actor text NOT NULL, action text NOT NULL, job_id bigint, detail jsonb
);
