BEGIN;
SET LOCAL plpgsql.check_asserts = on;

CREATE FUNCTION pg_temp.frame_indices(packet bytea)
RETURNS bytea LANGUAGE plpgsql AS $$
DECLARE
    data bytea := decode(repeat('00',16000),'hex');
    covered boolean[] := array_fill(false,ARRAY[16000]);
    offset_at integer := 0;
    encoded integer;
    dest integer;
    stride integer;
    run_length integer;
    i integer;
BEGIN
    WHILE offset_at < octet_length(packet) LOOP
        ASSERT offset_at + 4 <= octet_length(packet), 'truncated frame run header';
        encoded := get_byte(packet,offset_at)*256 + get_byte(packet,offset_at + 1);
        dest := encoded & 16383;
        stride := CASE WHEN (encoded & 16384) <> 0 THEN 160 ELSE 1 END;
        run_length := get_byte(packet,offset_at + 2);
        ASSERT encoded < 32768 AND dest < 16000 AND run_length > 0
            AND offset_at + 4 + run_length <= octet_length(packet), 'invalid frame run';
        ASSERT (stride = 1 AND dest % 160 + run_length <= 160)
            OR (stride = 160 AND dest / 160 + run_length <= 100), 'frame run crosses a viewport edge';
        FOR i IN 0..run_length - 1 LOOP
            ASSERT NOT covered[dest + 1], 'overlapping frame runs';
            covered[dest + 1] := true;
            data := set_byte(data,dest,get_byte(packet,offset_at + 4 + i));
            dest := dest + stride;
        END LOOP;
        offset_at := offset_at + 4 + run_length;
    END LOOP;
    ASSERT NOT (false = ANY(covered)), 'frame does not resolve all viewport pixels';
    RETURN data;
END;
$$;

DO $$
DECLARE
    level bigint;
    game bigint;
    idx bytea;
    colors bytea;
    frame record;
    prior bytea;
BEGIN
    INSERT INTO doom.levels(name) VALUES ('renderer portal fixture') RETURNING level_id INTO level;
    INSERT INTO doom.sectors(level_id,sector_id,floor_height,ceiling_height,light_level,floor_material,ceiling_material)
    VALUES (level,0,0,96,255,'F','C'), (level,1,0,96,255,'F','C');

    INSERT INTO doom.wad_sidedefs(level_id,side_id,sector_id,upper_material,middle_material)
    VALUES (level,0,0,'D',NULL), (level,1,1,NULL,'W');
    INSERT INTO doom.lines(level_id,line_id,x1,y1,x2,y2,front_sector_id,back_sector_id,front_side_id)
    VALUES (level,0,64,128,64,-128,0,1,0), (level,1,144,144,144,-144,1,NULL,1);
    INSERT INTO doom.wad_segs(level_id,seg_id,first_vertex_id,second_vertex_id,x1,y1,x2,y2,line_id,
        side,side_id,front_sector_id,back_sector_id,angle,"offset")
    VALUES (level,0,0,1,64,128,64,-128,0,0,0,0,1,0,0),
           (level,1,2,3,144,144,144,-144,1,0,1,1,NULL,0,0);
    INSERT INTO doom.wad_subsectors(level_id,subsector_id,first_seg_id,seg_count,sector_id)
    VALUES (level,0,0,1,0),(level,1,1,1,1);
    INSERT INTO doom.wad_bsp_nodes VALUES (level,0,64,0,0,1,-2,-1,144,-144,64,144,128,-128,0,64);

    SELECT decode(string_agg(lpad(to_hex(i),2,'0'),'' ORDER BY i),'hex') INTO idx FROM generate_series(0,255) AS x(i);
    SELECT decode(string_agg(repeat(lpad(to_hex(i),2,'0'),3),'' ORDER BY i),'hex') INTO colors
        FROM generate_series(0,255) AS x(i);
    INSERT INTO doom.level_palettes VALUES (level,colors,colors,decode(repeat(encode(idx,'hex'),32),'hex'));
    INSERT INTO doom.level_materials(level_id,surface_kind,name,width,height,pixels,coverage)
    VALUES (level,'flat','F',1,1,'\x11','\xff'), (level,'flat','C',1,1,'\x44','\xff'),
        (level,'wall','D',1,1,'\x22','\xff'), (level,'wall','W',1,1,'\x33','\xff');
    INSERT INTO doom.level_materials(level_id,surface_kind,name,width,height,left_offset,top_offset,pixels,coverage)
    VALUES (level,'sprite','S',32,48,16,48,decode(repeat('77',32*48),'hex'),
        decode(repeat(repeat('ff',7)||'00'||repeat('ff',40),32),'hex'));

    INSERT INTO doom.games(level_id,epoch,skill) VALUES (level,4,2) RETURNING game_id INTO game;
    INSERT INTO doom.actors(game_id,level_id,sector_id,type_id,kind,x,y,z,angle,health,sprite_material)
    VALUES (game,level,0,1,'player',0,0,0,0,100,NULL), (game,level,1,3004,'monster',96,0,0,0,10,'S');
    INSERT INTO doom.sector_state VALUES (game,level,1,0,0);
    PERFORM doom.compile_frame_assets(level);

    SELECT * INTO STRICT frame FROM doom.frame(game,4,10);
    ASSERT (frame.epoch,frame.tic,frame.slot,frame.palette_id) = (4,0,10,0), 'invalid frame identity';
    prior := pg_temp.frame_indices(frame.pixels);
    ASSERT get_byte(prior,50*160+80) = 34, 'closed door must occlude the far wall and actor';
    ASSERT octet_length(doom.frame_palette(game,0)) = 32*768, 'light palette must cover all COLORMAP rows';

    UPDATE doom.sector_state SET ceiling_height = 96 WHERE game_id = game AND sector_id = 1;
    UPDATE doom.games SET tick_number = 1 WHERE game_id = game;
    SELECT * INTO STRICT frame FROM doom.frame(game,4,11);
    idx := pg_temp.frame_indices(frame.pixels);
    ASSERT frame.tic = 1 AND idx <> prior, 'frame must sample committed game geometry';
    ASSERT get_byte(idx,50*160+80) = 51, 'a transparent sprite texel must reveal the wall behind it';
    ASSERT get_byte(idx,51*160+80) = 119, 'an opaque sprite texel must occlude the wall behind it';
    ASSERT get_byte(idx,98*160+80) = 17 AND get_byte(idx,1*160+80) = 68,
        'floor and ceiling spans must both be present';

    BEGIN
        PERFORM doom.frame(game,3,12);
        RAISE EXCEPTION 'stale epoch should be rejected';
    EXCEPTION WHEN invalid_parameter_value THEN
        NULL;
    END;
END;
$$;

ROLLBACK;
