-- Least-privilege login role for the api. The entrypoint runs this only when
-- the data directory is empty (first boot). It is idempotent, so the same file
-- applies the role to an existing volume or rotates its password (see
-- SOLUTION.md). Values come from the environment and are quoted with
-- format(%I/%L); nothing is interpolated by a shell.
\set ON_ERROR_STOP on
\getenv app_user APP_DB_USER
\getenv app_password APP_DB_PASSWORD
\if :{?app_user}
\else
  DO $$ BEGIN RAISE EXCEPTION 'APP_DB_USER is not set'; END $$;
\endif
\if :{?app_password}
\else
  DO $$ BEGIN RAISE EXCEPTION 'APP_DB_PASSWORD is not set'; END $$;
\endif
SELECT :'app_password' = '' AS app_password_empty \gset
\if :app_password_empty
  DO $$ BEGIN RAISE EXCEPTION 'APP_DB_PASSWORD is empty'; END $$;
\endif

SELECT format('CREATE ROLE %I LOGIN', :'app_user')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'app_user') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', :'app_user', :'app_password') \gexec

-- PUBLIC loses its default CONNECT and TEMPORARY, so only roles granted
-- CONNECT may log in. The api needs nothing more: SELECT NOW() and SELECT 1
-- touch no tables.
SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', current_database()) \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), :'app_user') \gexec
