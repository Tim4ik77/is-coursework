\set ON_ERROR_STOP on
SET search_path=clinic,public;
BEGIN;
UPDATE slot_holds SET expires_at=now()-interval '1 second' WHERE id=1;
CALL expire_holds();
DO $$ BEGIN
 IF (SELECT status FROM appointments WHERE id=4)<>'cancelled' OR (SELECT status FROM slot_holds WHERE id=1)<>'expired' THEN RAISE EXCEPTION 'Expiry did not release hold'; END IF;
END $$;
INSERT INTO waitlist_entries(patient_id,specialty_id,booking_type,preferred_from,preferred_until)
SELECT 4,1,'self',preferred_from,preferred_until FROM waitlist_entries WHERE id=1;
SELECT offer_slot(3,1) AS new_hold \gset
CALL decline_hold(:new_hold,4);
DO $$ BEGIN IF EXISTS(SELECT 1 FROM appointments WHERE slot_id=3 AND status<>'cancelled') THEN RAISE EXCEPTION 'Decline did not release slot'; END IF; END $$;
INSERT INTO episodes(patient_id,title,last_activity_at) VALUES(4,'Old empty episode',now()-interval '61 days');
UPDATE episodes SET last_activity_at=now()-interval '61 days' WHERE id=1;
CALL close_inactive_episodes();
DO $$ BEGIN
 IF (SELECT status FROM episodes WHERE title='Old empty episode')<>'closed' THEN RAISE EXCEPTION 'Idle episode not closed'; END IF;
 IF (SELECT status FROM episodes WHERE id=1)<>'active' THEN RAISE EXCEPTION 'Unfinished episode incorrectly closed'; END IF;
END $$;
SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;
\echo Lifecycle scenarios passed
