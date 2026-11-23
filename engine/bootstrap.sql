\o /dev/null
SELECT pg_advisory_lock(hashtext('doom.install'));
SELECT to_regnamespace('doom') IS NULL AS install \gset
\if :install
\ir ../install.sql
\else
SELECT to_regprocedure('doom.prepare_wad(bytea,text)') IS NULL AS upgrade \gset
\if :upgrade
BEGIN;
\ir wad/prepared.sql
COMMIT;
\endif
SELECT NOT coalesce(proconfig @> ARRAY['plan_cache_mode=force_generic_plan'], false) AS upgrade_mesh
FROM pg_proc WHERE oid='doom.compile_level(bigint)'::regprocedure \gset
\if :upgrade_mesh
ALTER FUNCTION doom.compile_level(bigint) SET plan_cache_mode=force_generic_plan;
\endif
SELECT prosqlbody IS NULL AS upgrade_palette
FROM pg_proc WHERE oid='doom.frame_palette(bigint)'::regprocedure \gset
\if :upgrade_palette
\ir render/palette.sql
\endif
\if :rife
SELECT to_regprocedure('doom.poll_frame_low(bigint,bigint,bigint,text)') IS NULL AS install_low \gset
\if :install_low
BEGIN;
\ir render/lowres.sql
COMMIT;
\endif
\endif
\endif
