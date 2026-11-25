-- ============================================================
-- Q8: TRANSPORT FLEET MAINTENANCE
-- ============================================================

-- ---------- (a) DATABASE: TABLES ----------
CREATE TABLE vehicles (
    vehicle_id            SERIAL PRIMARY KEY,
    registration          VARCHAR(15) NOT NULL UNIQUE,
    current_odometer      INT NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer INT NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT chk_service_le_current CHECK (last_service_odometer <= current_odometer)
);
CREATE TABLE trips (
    trip_id        SERIAL PRIMARY KEY,
    vehicle_id     INT NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on        DATE NOT NULL,
    start_odometer INT NOT NULL CHECK (start_odometer >= 0),
    end_odometer   INT NOT NULL CHECK (end_odometer >= 0)
);
CREATE TABLE service_alerts (
    vehicle_id       INT PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service INT NOT NULL,
    flagged_on       DATE NOT NULL
);

-- ---------- (b) FUNCTION ----------
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INT)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
DECLARE v_km INT;
BEGIN
    SELECT current_odometer - last_service_odometer INTO v_km
    FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle id: %', p_vehicle_id;
    END IF;
    RETURN v_km >= 5000;
END $$;

-- ---------- (c) PROCEDURE ----------
CREATE OR REPLACE PROCEDURE pr_record_trip(p_vehicle_id INT, p_trip_on DATE, p_start INT, p_end INT)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id) THEN
        RAISE EXCEPTION 'Unknown vehicle id: %', p_vehicle_id;
    END IF;
    IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL THEN
        RAISE EXCEPTION 'Trip date and odometer values are required';
    END IF;
    IF p_end <= p_start THEN
        RAISE EXCEPTION 'End odometer (%) must exceed start odometer (%)', p_end, p_start;
    END IF;

    INSERT INTO trips(vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);   -- odometer is updated by the trigger only
END $$;

-- ---------- (d) TRIGGER ----------
CREATE OR REPLACE FUNCTION trg_fn_trip_odometer() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_cur INT;
BEGIN
    SELECT current_odometer INTO v_cur FROM vehicles
    WHERE vehicle_id = NEW.vehicle_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle id: %', NEW.vehicle_id;
    END IF;
    IF NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage: end % must exceed start %',
              NEW.end_odometer, NEW.start_odometer;
    END IF;
    IF NEW.start_odometer <> v_cur THEN
        RAISE EXCEPTION 'Start odometer % does not match vehicle current odometer %',
              NEW.start_odometer, v_cur;
    END IF;

    UPDATE vehicles SET current_odometer = NEW.end_odometer
    WHERE vehicle_id = NEW.vehicle_id;      -- exactly once per inserted trip row
    RETURN NEW;
END $$;

CREATE TRIGGER trg_trip_odometer
BEFORE INSERT ON trips
FOR EACH ROW EXECUTE FUNCTION trg_fn_trip_odometer();

-- ---------- (a) SEED DATA (trips loaded through the procedure) ----------
INSERT INTO vehicles(registration, current_odometer, last_service_odometer) VALUES
 ('ZM1001', 10000,  8000),   -- 2,000 km since service
 ('ZM2002', 20000, 14000),   -- 6,000 km (due)
 ('ZM3003',  5000,     0);   -- exactly 5,000 km (due)

CALL pr_record_trip(1, '2026-11-01', 10000, 10300);
CALL pr_record_trip(1, '2026-11-05', 10300, 10800);
CALL pr_record_trip(2, '2026-11-02', 20000, 20400);
CALL pr_record_trip(2, '2026-11-08', 20400, 20900);
CALL pr_record_trip(3, '2026-11-03',  5000,  5200);
CALL pr_record_trip(3, '2026-11-09',  5200,  5600);

-- ---------- (e) VIEW ----------
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration, current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;

SELECT * FROM v_service_due;

-- ---------- (f) INDEX ----------
-- Equality on vehicle_id then range on trip_on: one contiguous slice of the index.
CREATE INDEX idx_trips_vehicle_trip_on ON trips(vehicle_id, trip_on);

-- SET enable_seqscan = off;
EXPLAIN
SELECT * FROM trips
WHERE vehicle_id = 1 AND trip_on BETWEEN '2026-11-01' AND '2026-11-30';

-- ---------- (g) SCHEDULED JOB ----------
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql AS $$
BEGIN
    -- remove alerts for vehicles that are no longer due (e.g. after service)
    DELETE FROM service_alerts sa
    WHERE NOT EXISTS (
        SELECT 1 FROM vehicles v
        WHERE v.vehicle_id = sa.vehicle_id
          AND v.current_odometer - v.last_service_odometer >= 5000);

    -- insert or update one alert per due vehicle
    INSERT INTO service_alerts(vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
    FROM vehicles
    WHERE current_odometer - last_service_odometer >= 5000
    ON CONFLICT (vehicle_id) DO UPDATE
    SET km_since_service = EXCLUDED.km_since_service;   -- keeps the original flagged_on
END $$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh_service_alerts', '0 6 * * 1', $$CALL pr_refresh_service_alerts()$$);