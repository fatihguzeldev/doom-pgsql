\echo 'connected to' :HOST
\set ON_ERROR_STOP on
\set QUIET on

CREATE TEMP TABLE playing AS
SELECT DISTINCT g.id, l.name AS map
FROM pg_stat_activity a
JOIN doom.games g ON a.application_name = 'doom-pgsql/' || g.id
JOIN doom.levels l ON l.id = g.level
WHERE a.datname = current_database() AND NOT g.finished;

SELECT count(*) > 1 AND NOT :{?game} AS choose FROM playing \gset
\if :choose
TABLE playing;
\prompt 'game id: ' game
\endif
\if :{?game}
SELECT EXISTS (SELECT FROM playing WHERE id = :'game'::bigint) AS found \gset
\else
SELECT count(*) = 1 AS found, min(id) AS game FROM playing \gset
\endif
\if :found
SELECT map FROM playing WHERE id = :'game'::bigint \gset
CREATE TEMP VIEW player AS
    SELECT health, yaw FROM doom.actors WHERE game = :'game'::bigint AND id = -1;
CREATE TEMP VIEW inventory AS
    SELECT ammo, armor FROM doom.games WHERE id = :'game'::bigint;
\echo :map / game :game
\else
\unset game
\echo 'no matching game is open. start a map, then reconnect.'
\endif
\unset QUIET
