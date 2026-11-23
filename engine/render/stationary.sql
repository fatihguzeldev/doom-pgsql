ALTER TABLE doom.games ADD COLUMN cache_stationary boolean NOT NULL DEFAULT true;
CREATE OR REPLACE TRIGGER anchor_stationary AFTER UPDATE OF still_tics ON doom.games
FOR EACH ROW WHEN (NEW.cache_stationary AND NEW.still_tics=4 AND OLD.still_tics<>4)
EXECUTE FUNCTION doom.anchor_stationary_game();
