CREATE OR REPLACE FUNCTION doom.frame_palette(gid bigint) RETURNS bytea LANGUAGE sql STABLE STRICT
BEGIN ATOMIC
    -- Read the colormap once and sort only its indices.
    WITH colors AS MATERIALIZED (
        SELECT l.palette,substring(l.lighting FOR 32*256) AS lighting
        FROM doom.games g JOIN doom.levels l ON l.id=g.level WHERE g.id=gid
    )
    SELECT (
        SELECT string_agg(substring(c.palette FROM 1+3*get_byte(c.lighting,i) FOR 3),''::bytea ORDER BY i)
        FROM generate_series(0,length(c.lighting)-1)i
    ) FROM colors c;
END;
