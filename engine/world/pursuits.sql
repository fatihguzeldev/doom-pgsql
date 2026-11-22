CREATE TABLE doom.actor_pursuits (
    kind text PRIMARY KEY REFERENCES doom.actor_types ON DELETE CASCADE CHECK (kind <> 'player'),
    sight_range integer NOT NULL CHECK (sight_range > 0),
    move_distance integer NOT NULL CHECK (move_distance >= 0),
    interval_ticks integer NOT NULL CHECK (interval_ticks > 0)
);
