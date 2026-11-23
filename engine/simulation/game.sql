CREATE TYPE doom.command AS (forward float8,strafe float8,turn float8,use_line boolean,fire boolean);
CREATE TABLE doom.games (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, level bigint NOT NULL REFERENCES doom.levels,
    epoch bigint NOT NULL DEFAULT 1, tic bigint NOT NULL DEFAULT 0, difficulty int NOT NULL CHECK(difficulty BETWEEN 1 AND 5),
    last_command doom.command, finished boolean NOT NULL DEFAULT false, secret_exit boolean NOT NULL DEFAULT false, ammo int NOT NULL DEFAULT 50,
    still_tics smallint NOT NULL DEFAULT 0,
    armor int NOT NULL DEFAULT 0, keys int NOT NULL DEFAULT 0, next_shot bigint NOT NULL DEFAULT 0
) WITH (fillfactor=80);
CREATE TABLE doom.actors (
    game bigint REFERENCES doom.games ON DELETE CASCADE, id int, sector int NOT NULL, pos point NOT NULL,
    z float8 NOT NULL, yaw float8 NOT NULL, code int NOT NULL REFERENCES doom.thing_types,
    role text NOT NULL, art int REFERENCES doom.art, health int NOT NULL, radius int NOT NULL,height int NOT NULL,
    awake_at bigint NOT NULL DEFAULT 0,
    cell_x int GENERATED ALWAYS AS (floor(pos[0]/128)::int) STORED,
    cell_y int GENERATED ALWAYS AS (floor(pos[1]/128)::int) STORED,
    PRIMARY KEY(game,id)
) WITH (fillfactor=80);
CREATE INDEX actors_nearby ON doom.actors(game,cell_x,cell_y);
CREATE INDEX actors_due ON doom.actors(game,(id%8)) WHERE role='monster' AND health>0;

CREATE TABLE doom.movers (
    game bigint REFERENCES doom.games ON DELETE CASCADE, sector int,
    floor_z int NOT NULL,ceiling_z int NOT NULL,plane text NOT NULL CHECK(plane IN ('floor','ceiling')),
    target int NOT NULL, home int, speed int NOT NULL CHECK(speed>0), resume_at bigint,wait_tics int NOT NULL,
    PRIMARY KEY(game,sector)
);
CREATE TABLE doom.room_changes (
    game bigint REFERENCES doom.games ON DELETE CASCADE, sector int, light int CHECK(light BETWEEN 0 AND 255),
    floor_id int REFERENCES doom.art, PRIMARY KEY(game,sector)
);
CREATE TABLE doom.used_lines(game bigint REFERENCES doom.games ON DELETE CASCADE,line int,PRIMARY KEY(game,line));

CREATE FUNCTION doom.new_game(p_level bigint,skill int DEFAULT 3)
RETURNS TABLE(game_id bigint,epoch bigint,tic bigint) LANGUAGE plpgsql AS $$
DECLARE
    g bigint;
BEGIN
    PERFORM 1 FROM doom.levels WHERE id=p_level AND ready FOR SHARE;
    INSERT INTO doom.games(level,difficulty) SELECT id,skill FROM doom.levels WHERE id=p_level AND ready RETURNING id INTO STRICT g;
    INSERT INTO doom.actors(game,id,sector,pos,z,yaw,code,role,art,health,radius,height)
    SELECT g,CASE WHEN t.role='player' THEN -1 ELSE s.id END,r.id,s.pos,r.floor_z,radians(s.angle),
        t.code,t.role,a.id,t.hp,t.radius,t.height
    FROM doom.spawns s JOIN doom.thing_types t ON t.code=s.thing
    JOIN doom.sectors r ON r.level=p_level AND r.id=doom.sector_at(p_level,s.pos)
    LEFT JOIN doom.art a ON (a.level,a.kind,a.name)=(p_level,'sprite',t.sprite)
    WHERE s.level=p_level AND (s.id=(SELECT min(id) FROM doom.spawns WHERE level=p_level AND thing=1)
        OR (t.role<>'player' AND (s.flags&16)=0 AND (s.flags & CASE WHEN skill<=2 THEN 1 WHEN skill=3 THEN 2 ELSE 4 END)<>0));
    IF NOT EXISTS(SELECT FROM doom.actors a WHERE a.game=g AND a.id=-1) THEN RAISE EXCEPTION 'missing player start'; END IF;
    RETURN QUERY SELECT g,1::bigint,0::bigint;
END;
$$;
CREATE FUNCTION doom.game_status(g bigint) RETURNS TABLE(game_id bigint,epoch bigint,tic bigint,finished boolean)
LANGUAGE sql STABLE STRICT AS $$ SELECT id,epoch,tic,finished FROM doom.games WHERE id=g $$;
