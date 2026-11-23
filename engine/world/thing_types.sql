CREATE TABLE doom.thing_types (
    code int PRIMARY KEY, sprite text, role text NOT NULL, hp int NOT NULL DEFAULT 1,
    radius int NOT NULL DEFAULT 12, height int NOT NULL DEFAULT 16
);
INSERT INTO doom.thing_types(code,sprite,role,hp,radius,height) VALUES
    (1,NULL,'player',100,16,56),(3004,'POSSA1','monster',20,20,56),(9,'SPOSA1','monster',30,20,56),
    (3001,'TROOA1','monster',60,20,56),(3002,'SARGA1','monster',150,30,56),
    (58,'SARGA1','monster',150,30,56),(3003,'BOSSA1','monster',1000,24,64),
    (3005,'HEADA1','monster',400,31,56),(3006,'SKULA1','monster',100,16,56),(2035,'BAR1A0','barrel',20,10,42);
INSERT INTO doom.thing_types(code,sprite,role)
SELECT code,sprite,'pickup' FROM (VALUES
    (5,'BKEYA0'),(6,'YKEYA0'),(13,'RKEYA0'),(38,'RSKUA0'),(39,'YSKUA0'),(40,'BSKUA0'),
    (2001,'SHOTA0'),(2002,'MGUNA0'),(2003,'LAUNA0'),(2004,'PLASA0'),(2005,'CSAWA0'),(2006,'BFUGA0'),
    (2007,'CLIPA0'),(2008,'SHELA0'),(2010,'ROCKA0'),(2047,'CELLA0'),(2048,'AMMOA0'),(2049,'SBOXA0'),
    (2011,'STIMA0'),(2012,'MEDIA0'),(2013,'SOULA0'),(2014,'BON1A0'),(2015,'BON2A0'),
    (2018,'ARM1A0'),(2019,'ARM2A0'),(2022,'PINVA0'),(2023,'PSTRA0'),(2024,'PINSA0'),
    (2025,'SUITA0'),(2026,'PMAPA0'),(2045,'PVISA0'),(8,'BPAKA0'),(17,'CELPA0'),(2046,'BROKA0')
) AS item(code,sprite);
INSERT INTO doom.thing_types(code,sprite,role)
SELECT code,sprite,'decor' FROM (VALUES
    (10,'PLAYW0'),(12,'PLAYW0'),(15,'PLAYN0'),(18,'POSSL0'),(19,'SPOSL0'),(20,'TROOM0'),
    (21,'SARGN0'),(22,'HEADL0'),(24,'POL5A0'),(34,'CANDA0'),(35,'CBRAA0'),(44,'TBLUA0'),
    (45,'TGRNA0'),(46,'TREDA0'),(48,'ELECA0'),(2028,'COLUA0')) AS prop(code,sprite);
