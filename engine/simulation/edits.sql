-- Sector -1 marks actors left outside the mesh by a map edit.
CREATE FUNCTION doom.relocate_after_edit() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    WITH positions AS MATERIALIZED (
        SELECT a.game,a.id,doom.sector_at(NEW.id,a.pos) AS sector
        FROM doom.games g JOIN doom.actors a ON a.game=g.id WHERE g.level=NEW.id
    )
    UPDATE doom.actors a SET sector=coalesce(p.sector,-1),z=coalesce(m.floor_z,s.floor_z,a.z)
    FROM positions p LEFT JOIN doom.sectors s ON s.level=NEW.id AND s.id=p.sector
    LEFT JOIN doom.movers m ON m.game=p.game AND m.sector=p.sector
    WHERE (a.game,a.id)=(p.game,p.id) AND a.sector<>coalesce(p.sector,-1);
    RETURN NULL;
END;
$$;
CREATE TRIGGER relocate_actors AFTER UPDATE OF geometry_revision ON doom.levels
FOR EACH ROW EXECUTE FUNCTION doom.relocate_after_edit();

CREATE FUNCTION doom.follow_edited_floor() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    UPDATE doom.actors a SET z=current.floor_z
    FROM before_edit prior JOIN after_edit current USING(level,id) JOIN doom.games g ON g.level=current.level
    WHERE a.game=g.id AND a.sector=current.id AND a.z=prior.floor_z AND current.floor_z<>prior.floor_z
        AND NOT EXISTS(SELECT FROM doom.movers m WHERE m.game=g.id AND m.sector=current.id);
    RETURN NULL;
END;
$$;
CREATE TRIGGER follow_floor AFTER UPDATE ON doom.sectors REFERENCING OLD TABLE AS before_edit NEW TABLE AS after_edit
FOR EACH STATEMENT EXECUTE FUNCTION doom.follow_edited_floor();
