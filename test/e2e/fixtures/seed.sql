-- Seed data for the end-to-end suite. Loaded once into the e2e_seed template
-- database; each test clones it with CREATE DATABASE ... TEMPLATE e2e_seed.
-- Deterministic on purpose (no now() or random()) so fingerprints are stable.

CREATE SCHEMA app;
CREATE SCHEMA "Mixed Case";

CREATE TABLE app.users (
  id serial PRIMARY KEY,
  email text NOT NULL UNIQUE,
  name text,
  created_at timestamptz NOT NULL DEFAULT '2024-01-01 00:00:00+00',
  profile jsonb,
  tags text[],
  avatar bytea,
  balance numeric(12, 2)
);
COMMENT ON TABLE app.users IS 'Users with awkward data: unicode, quotes, NULLs';

INSERT INTO app.users (email, name, created_at, profile, tags, avatar, balance)
SELECT
  'user' || i || '@example.com',
  CASE i % 6
    WHEN 0 THEN 'Zoë O''Brien'
    WHEN 1 THEN '日本語の名前 ' || i
    WHEN 2 THEN 'emoji 🐘 ' || i
    WHEN 3 THEN E'tab\tnew\nline\\back ' || i
    WHEN 4 THEN NULL
    ELSE 'plain ' || i
  END,
  '2024-01-01 00:00:00+00'::timestamptz + (i || ' minutes')::interval,
  jsonb_build_object('i', i, 'even', i % 2 = 0, 'nested', jsonb_build_object('k', md5(i::text))),
  ARRAY['t' || (i % 7), 't' || (i % 11)],
  decode(md5(i::text), 'hex'),
  (i * 1.25)::numeric(12, 2)
FROM generate_series(1, 20000) AS i;

CREATE TABLE app.orders (
  id bigserial PRIMARY KEY,
  user_id integer NOT NULL REFERENCES app.users (id),
  amount numeric(10, 2) NOT NULL CHECK (amount >= 0),
  status text NOT NULL DEFAULT 'new',
  updated_at timestamptz
);
CREATE INDEX orders_user_id_idx ON app.orders (user_id);

INSERT INTO app.orders (user_id, amount, status)
SELECT (i % 20000) + 1, (i % 1000) / 10.0, (ARRAY['new', 'paid', 'shipped'])[(i % 3) + 1]
FROM generate_series(1, 40000) AS i;

CREATE FUNCTION app.touch_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := '2025-01-01 00:00:00+00';
  RETURN NEW;
END
$$;
CREATE TRIGGER orders_touch BEFORE UPDATE ON app.orders
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();

CREATE FUNCTION app.add(a integer, b integer) RETURNS integer
LANGUAGE sql IMMUTABLE AS 'SELECT a + b';

CREATE VIEW app.user_order_totals AS
SELECT u.id, u.email, coalesce(sum(o.amount), 0) AS total
FROM app.users u LEFT JOIN app.orders o ON o.user_id = u.id
GROUP BY u.id, u.email;

CREATE MATERIALIZED VIEW app.status_counts AS
SELECT status, count(*) AS n FROM app.orders GROUP BY status;

CREATE SEQUENCE app.invoice_seq;
SELECT setval('app.invoice_seq', 42);

CREATE TABLE app.events (
  id integer NOT NULL,
  happened_on date NOT NULL,
  payload text
) PARTITION BY RANGE (happened_on);
CREATE TABLE app.events_2024 PARTITION OF app.events
  FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');
CREATE TABLE app.events_2025 PARTITION OF app.events
  FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');
INSERT INTO app.events
SELECT i, DATE '2024-06-01' + (i % 400), 'event ' || i
FROM generate_series(1, 2000) AS i;

CREATE TABLE "Mixed Case"."Weird Table" ("Col" text, "select" integer);
INSERT INTO "Mixed Case"."Weird Table" VALUES ('needs quoting', 1), (NULL, 2);

-- Excluded by POSTGRES_EXTRA_DUMP_OPTS tests.
CREATE TABLE public.excluded_table (id integer PRIMARY KEY, note text);
INSERT INTO public.excluded_table SELECT i, 'excluded ' || i FROM generate_series(1, 10) AS i;

SELECT lo_from_bytea(424242, convert_to('large object payload', 'UTF8'));
