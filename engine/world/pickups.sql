CREATE TABLE doom.health_pickups (
    kind text PRIMARY KEY REFERENCES doom.actor_types ON DELETE CASCADE CHECK (kind <> 'player'),
    amount integer NOT NULL CHECK (amount > 0)
);
