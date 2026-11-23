-- Select the nearest neighbour plane in the live game for each activated sector.
CREATE FUNCTION doom.activate(g doom.games,line_no int,mode text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    l doom.lines;
    door boolean;
    lift boolean;
    repeatable boolean;
    r record;
    goal int;
    required_key int;
BEGIN
    SELECT * INTO STRICT l FROM doom.lines WHERE level=g.level AND id=line_no;
    IF l.special=0 OR EXISTS (SELECT FROM doom.used_lines WHERE game=g.id AND line=line_no) THEN RETURN; END IF;
    IF l.special IN (11,51,52,124) THEN
        IF (l.special IN (11,51) AND mode='use') OR (l.special IN (52,124) AND mode='cross') THEN
            UPDATE doom.games SET finished=true WHERE id=g.id;
        END IF;
        RETURN;
    END IF;
    IF l.special IN (39,97) AND mode='cross' THEN
        UPDATE doom.actors a SET pos=dst.pos,sector=dst.sector,z=dst.floor_z,yaw=radians(dst.angle)
        FROM (SELECT s.pos,s.angle,r.id AS sector,r.floor_z FROM doom.spawns s
            JOIN doom.sectors r ON r.level=s.level AND r.id=doom.sector_at(s.level,s.pos)
            WHERE s.level=g.level AND s.thing=14 AND r.tag=l.tag ORDER BY s.id LIMIT 1) dst
        WHERE a.game=g.id AND a.id=-1;
        RETURN;
    END IF;
    door := l.special IN (1,2,3,4,16,26,27,28,29,31,32,33,34,42,46,50,61,63,75,76,86,90,99,103,105,106,107,108,109,110,111,112,113,114,115,116,117,118);
    lift := l.special IN (10,21,62,88,120,121,122,123);
    IF NOT door AND NOT lift AND l.special NOT IN (5,18,19,23,24,30,36,38,45,55,56,58,69,70,71,82,83,91,92,93,98,101,102,119,128,129,130,131,132) THEN RETURN; END IF;
    IF l.special IN (24,46) THEN
        IF mode<>'shoot' THEN RETURN; END IF;
    ELSIF l.special IN (2,3,4,5,10,16,19,30,36,38,56,58,75,76,82,83,86,88,90,91,92,93,98,105,106,107,108,109,110,119,120,121,128,129,130) THEN
        IF mode<>'cross' THEN RETURN; END IF;
    ELSIF mode<>'use' THEN RETURN;
    END IF;
    required_key := CASE WHEN l.special IN (26,32,99) THEN 1 WHEN l.special IN (27,34) THEN 2
        WHEN l.special IN (28,33) THEN 4 ELSE 0 END;
    IF required_key<>0 AND (g.keys & required_key)=0 THEN RETURN; END IF;
    repeatable := l.special IN (1,26,27,28,42,45,46,61,62,63,69,70,75,76,82,83,86,88,90,91,92,93,98,99,105,106,107,114,115,116,117,120,123,128,129,132);
    FOR r IN SELECT s.*,coalesce(m.floor_z,s.floor_z) AS f,coalesce(m.ceiling_z,s.ceiling_z) AS c
        FROM doom.sectors s LEFT JOIN doom.movers m ON m.game=g.id AND m.sector=s.id
        WHERE s.level=g.level AND CASE WHEN l.tag<>0 THEN s.tag=l.tag
            ELSE s.id=(SELECT sector FROM doom.sides WHERE level=g.level AND id=l.back) END
    LOOP
        SELECT CASE WHEN door THEN min(coalesce(nm.ceiling_z,n.ceiling_z))-4 WHEN lift OR
            l.special IN (19,23,36,38,45,70,71,82,83,98,102) THEN min(coalesce(nm.floor_z,n.floor_z))
            ELSE min(coalesce(nm.floor_z,n.floor_z)) FILTER (WHERE coalesce(nm.floor_z,n.floor_z)>r.f) END INTO goal
        FROM doom.mesh mesh,unnest(mesh.edges)e JOIN doom.sectors n ON n.level=g.level AND n.id=e.dest
        LEFT JOIN doom.movers nm ON nm.game=g.id AND nm.sector=e.dest
        WHERE mesh.level=g.level AND mesh.sector=r.id AND e.dest<>r.id;
        IF door AND l.special IN (3,16,42,50,75,76,107,110,113,116) THEN goal:=r.f; END IF;
        IF goal IS NULL THEN CONTINUE; END IF;
        INSERT INTO doom.movers VALUES(g.id,r.id,r.f,r.c,CASE WHEN door THEN 'ceiling' ELSE 'floor' END,
            goal,CASE WHEN lift THEN r.f WHEN door AND l.special IN (1,4,26,27,28,29,63,90,105,108,111,114,117) THEN r.f END,
            CASE WHEN l.special BETWEEN 105 AND 123 THEN 8 WHEN door THEN 2 ELSE 4 END,NULL,CASE WHEN door THEN 150 ELSE 105 END)
        ON CONFLICT(game,sector) DO UPDATE SET plane=excluded.plane,target=excluded.target,home=excluded.home,
            speed=excluded.speed,resume_at=NULL,wait_tics=excluded.wait_tics;
    END LOOP;
    IF NOT repeatable THEN INSERT INTO doom.used_lines VALUES(g.id,line_no) ON CONFLICT DO NOTHING; END IF;
END;
$$;

CREATE FUNCTION doom.advance(g bigint,n bigint) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    m doom.movers;
    current_z int;
    new_z int;
BEGIN
    FOR m IN SELECT * FROM doom.movers WHERE game=g AND (resume_at IS NULL OR resume_at<=n)
        AND (target<>CASE WHEN plane='floor' THEN floor_z ELSE ceiling_z END OR home IS NOT NULL) ORDER BY sector FOR UPDATE
    LOOP
        current_z := CASE WHEN m.plane='floor' THEN m.floor_z ELSE m.ceiling_z END;
        new_z := current_z+sign(m.target-current_z)::int*least(m.speed,abs(m.target-current_z));
        IF m.plane='floor' THEN
            UPDATE doom.actors SET z=new_z WHERE game=g AND sector=m.sector AND z=current_z;
            m.floor_z := new_z;
        ELSE
            IF new_z<current_z AND EXISTS(SELECT FROM doom.actors WHERE game=g AND sector=m.sector
                AND role IN ('monster','player') AND health>0 AND z+height>new_z) THEN CONTINUE; END IF;
            m.ceiling_z := new_z;
        END IF;
        UPDATE doom.movers SET floor_z=m.floor_z,ceiling_z=m.ceiling_z,
            resume_at=CASE WHEN new_z=m.target AND m.home IS NOT NULL THEN n+m.wait_tics END,
            target=CASE WHEN new_z=m.target THEN coalesce(m.home,m.target) ELSE m.target END,
            home=CASE WHEN new_z<>m.target THEN m.home END WHERE game=g AND sector=m.sector;
    END LOOP;
END;
$$;
