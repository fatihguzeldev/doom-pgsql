CREATE TYPE doom._render_mapping AS (
    surface_kind text,
    material_name text,
    light integer,
    u double precision,
    v double precision,
    du double precision,
    dv double precision,
    radial boolean
);

CREATE TYPE doom._render_span AS (
    column_x integer,
    row_start integer,
    row_end integer,
    rgb bytea,
    mapping doom._render_mapping
);
