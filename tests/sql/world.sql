DO $$
BEGIN
    ASSERT (SELECT count(*)=4 FROM doom.cells(point(1,1),point(200,200)));
    ASSERT (SELECT count(*)=4 FROM doom.cells(point(128,20),point(128,200)));
    ASSERT NOT EXISTS ((SELECT * FROM doom.cells(point(-33,128),point(300,-16)))
        EXCEPT (SELECT * FROM doom.cells(point(300,-16),point(-33,128))));
END;
$$;
