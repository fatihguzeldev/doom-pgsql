CREATE TYPE doom.image AS (w int,h int,origin_x int,origin_y int,pixels bytea,mask bytea);

-- Pixels are column-major. A NULL mask means every pixel is opaque.
CREATE FUNCTION doom.compose(w int,h int,patches bytea[],xs int[],ys int[])
RETURNS doom.image LANGUAGE plpgsql IMMUTABLE STRICT AS $$
DECLARE
    blank bytea;
    columns bytea[];
    coverage bytea[];
    patch bytea;
    pw int;
    cursor_at int;
    patch_y int;
    previous_y int;
    count_y int;
    x int;
    y int;
    skip int;
    keep int;
    opaque bytea;
BEGIN
    IF w NOT BETWEEN 1 AND 4096 OR h NOT BETWEEN 1 AND 4096 THEN
        RAISE EXCEPTION 'invalid image size % by %',w,h USING ERRCODE='22023';
    END IF;
    blank := decode(repeat('00',h),'hex');
    opaque := decode(repeat('ff',h),'hex');
    columns := array_fill(blank,ARRAY[w]);
    coverage := columns;
    FOR k IN 1..cardinality(patches) LOOP
        patch := patches[k];
        IF patch IS NULL THEN RAISE EXCEPTION 'texture refers to a missing patch'; END IF;
        pw := doom.u16(patch,0);
        FOR px IN greatest(0,-xs[k])..least(pw-1,w-1-xs[k]) LOOP
            x := 1+xs[k]+px;
            cursor_at := doom.u32(patch,8+px*4);
            previous_y := -1;
            LOOP
                patch_y := get_byte(patch,cursor_at);
                EXIT WHEN patch_y=255;
                IF patch_y<=previous_y THEN patch_y := patch_y+previous_y; END IF;
                previous_y := patch_y;
                count_y := get_byte(patch,cursor_at+1);
                IF cursor_at+4+count_y>length(patch) THEN RAISE EXCEPTION 'incomplete patch post'; END IF;
                y := ys[k]+patch_y;
                skip := greatest(0,-y);
                keep := least(count_y-skip,h-greatest(y,0));
                IF keep>0 THEN
                    columns[x] := overlay(columns[x] PLACING substring(patch FROM cursor_at+4+skip FOR keep)
                                          FROM greatest(y,0)+1 FOR keep);
                    coverage[x] := overlay(coverage[x] PLACING substring(opaque FOR keep) FROM greatest(y,0)+1 FOR keep);
                END IF;
                cursor_at := cursor_at+count_y+4;
            END LOOP;
        END LOOP;
    END LOOP;
    RETURN (w,h,0,0,(SELECT string_agg(c,''::bytea ORDER BY i) FROM unnest(columns) WITH ORDINALITY col(c,i)),
        CASE WHEN EXISTS(SELECT FROM unnest(coverage)c WHERE c<>opaque) THEN
            (SELECT string_agg(c,''::bytea ORDER BY i) FROM unnest(coverage) WITH ORDINALITY col(c,i)) END)::doom.image;
END;
$$;

CREATE FUNCTION doom.sky_name(map_name text) RETURNS text LANGUAGE sql IMMUTABLE STRICT
RETURN CASE WHEN map_name ~ '^E[2-4]M' THEN 'SKY'||substring(map_name FROM 2 FOR 1)
    WHEN map_name ~ '^MAP[0-9]{2}$' THEN CASE WHEN right(map_name,2)::int<12 THEN 'SKY1'
        WHEN right(map_name,2)::int<21 THEN 'SKY2' ELSE 'SKY3' END ELSE 'SKY1' END;

CREATE FUNCTION doom.read_art(p bigint,wad bytea,catalog jsonb) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    directory bytea;
    patch_names bytea := doom.lump_data(wad,catalog,'PNAMES');
    name text;
    data bytea;
    wanted text[];
    tex int;
    at_patch int;
    parts bytea[];
    offsets_x int[];
    offsets_y int[];
    pic doom.image;
BEGIN
    FOR name IN SELECT floor_tex FROM doom.sectors WHERE level=p UNION SELECT ceiling_tex FROM doom.sectors WHERE level=p LOOP
        data := doom.lump_data(wad,catalog,name);
        IF length(data)=4096 THEN INSERT INTO doom.art(level,kind,name,w,h,pixels) VALUES(p,'flat',name,64,64,data); END IF;
    END LOOP;
    FOR name IN SELECT DISTINCT t.sprite FROM doom.spawns s JOIN doom.thing_types t ON t.code=s.thing
                WHERE s.level=p AND t.sprite IS NOT NULL LOOP
        data := doom.lump_data(wad,catalog,name);
        CONTINUE WHEN data IS NULL;
        pic := doom.compose(doom.u16(data,0),doom.u16(data,2),ARRAY[data],ARRAY[0],ARRAY[0]);
        INSERT INTO doom.art(level,kind,name,w,h,origin_x,origin_y,pixels,mask)
        VALUES(p,'sprite',name,pic.w,pic.h,doom.s16(data,4),doom.s16(data,6),pic.pixels,pic.mask);
    END LOOP;
    SELECT array_agg(DISTINCT n) INTO wanted FROM (
        SELECT unnest(ARRAY[upper_tex,lower_tex,middle_tex]) AS n FROM doom.sides WHERE level=p
        UNION ALL SELECT doom.sky_name(l.name) FROM doom.levels l WHERE l.id=p
    ) names WHERE n IS NOT NULL;
    FOREACH directory IN ARRAY ARRAY[doom.lump_data(wad,catalog,'TEXTURE1'),doom.lump_data(wad,catalog,'TEXTURE2')] LOOP
        CONTINUE WHEN directory IS NULL;
        FOR i IN 0..doom.u32(directory,0)::int-1 LOOP
            tex := doom.u32(directory,4+i*4);
            name := doom.label(directory,tex);
            CONTINUE WHEN NOT(name=ANY(wanted));
            parts := '{}'; offsets_x := '{}'; offsets_y := '{}';
            FOR k IN 0..doom.u16(directory,tex+20)-1 LOOP
                at_patch := tex+22+k*10;
                parts := array_append(parts,doom.lump_data(wad,catalog,
                    doom.label(patch_names,4+8*doom.u16(directory,at_patch+4))));
                offsets_x := array_append(offsets_x,doom.s16(directory,at_patch));
                offsets_y := array_append(offsets_y,doom.s16(directory,at_patch+2));
            END LOOP;
            pic := doom.compose(doom.u16(directory,tex+12),doom.u16(directory,tex+14),parts,offsets_x,offsets_y);
            INSERT INTO doom.art(level,kind,name,w,h,pixels,mask) VALUES(p,'wall',name,pic.w,pic.h,pic.pixels,pic.mask)
            ON CONFLICT DO NOTHING;
        END LOOP;
    END LOOP;
END;
$$;
