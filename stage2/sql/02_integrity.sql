SET search_path = clinic, public;
-- A conservative single writer lock makes cross-table checks deterministic.
-- READ COMMITTED is required; readers remain concurrent. See report for scaling limits.
CREATE FUNCTION serialize_writes() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF current_setting('transaction_isolation') <> 'read committed' THEN
  RAISE EXCEPTION 'clinic writes require READ COMMITTED';
 END IF;
 PERFORM pg_advisory_xact_lock(742031,2);
 RETURN NULL;
END $$;
DO $$ DECLARE t record; BEGIN
 FOR t IN SELECT tablename FROM pg_tables WHERE schemaname='clinic' LOOP
  EXECUTE format('CREATE TRIGGER serialize BEFORE INSERT OR UPDATE OR DELETE ON clinic.%I FOR EACH STATEMENT EXECUTE FUNCTION clinic.serialize_writes()',t.tablename);
 END LOOP;
END $$;

CREATE FUNCTION guard_appointment() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE s record; a record;
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Keep appointment history; cancel instead'; END IF;
 IF TG_OP='UPDATE' THEN
  IF OLD.status IN ('completed','no_show','cancelled') THEN RAISE EXCEPTION 'Terminal appointment is immutable'; END IF;
  IF ROW(NEW.patient_id,NEW.slot_id,NEW.booking_type,NEW.care_action_id,NEW.created_by_user_id,NEW.created_at)
    IS DISTINCT FROM ROW(OLD.patient_id,OLD.slot_id,OLD.booking_type,OLD.care_action_id,OLD.created_by_user_id,OLD.created_at)
  THEN RAISE EXCEPTION 'Cancel and rebook to move an appointment'; END IF;
  IF NEW.status='held' AND OLD.status<>'held' THEN RAISE EXCEPTION 'Cannot return to held'; END IF;
  IF OLD.status='held' AND NEW.status NOT IN ('held','planned','cancelled') THEN RAISE EXCEPTION 'Invalid hold transition'; END IF;
 ELSE
  IF NEW.status NOT IN ('planned','held') THEN RAISE EXCEPTION 'New appointment must be planned or held'; END IF;
 END IF;
 SELECT t.*,d.specialty_id INTO STRICT s FROM time_slots t JOIN doctor_schedules d ON d.id=t.schedule_id WHERE t.id=NEW.slot_id;
 NEW.starts_at := s.starts_at; NEW.ends_at := s.ends_at;
 IF TG_OP='INSERT' AND s.starts_at <= clock_timestamp() THEN RAISE EXCEPTION 'Slot is in the past'; END IF;
 IF NEW.booking_type='self' THEN
  IF NOT (SELECT self_booking_allowed FROM specialties WHERE id=s.specialty_id) THEN RAISE EXCEPTION 'Referral required'; END IF;
 ELSE
  SELECT c.*,e.patient_id INTO STRICT a FROM care_actions c JOIN episodes e ON e.id=c.episode_id WHERE c.id=NEW.care_action_id;
  IF a.patient_id<>NEW.patient_id OR a.kind<>NEW.booking_type OR a.target_specialty_id<>s.specialty_id THEN RAISE EXCEPTION 'Invalid referral patient, kind or specialty'; END IF;
  IF TG_OP='INSERT' AND a.status<>'assigned' THEN RAISE EXCEPTION 'Action is not available'; END IF;
  NEW.episode_id:=a.episode_id;
 END IF;
 IF TG_OP='UPDATE' AND NEW.episode_id IS DISTINCT FROM OLD.episode_id AND EXISTS(SELECT 1 FROM medical_notes WHERE appointment_id=OLD.id) THEN RAISE EXCEPTION 'Cannot reassign episode after writing a note'; END IF;
 IF NEW.status='completed' AND (NEW.episode_id IS NULL OR NOT EXISTS(SELECT 1 FROM medical_notes WHERE appointment_id=NEW.id)) THEN
  RAISE EXCEPTION 'Completion requires episode and medical note';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER appointment_guard BEFORE INSERT OR UPDATE OR DELETE ON appointments FOR EACH ROW EXECUTE FUNCTION guard_appointment();

CREATE FUNCTION appointment_effects() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.care_action_id IS NOT NULL THEN
  UPDATE care_actions SET status=CASE WHEN NEW.status IN ('cancelled','no_show') THEN 'assigned' WHEN NEW.status='completed' THEN 'completed' ELSE 'booked' END WHERE id=NEW.care_action_id;
 END IF;
 IF NEW.episode_id IS NOT NULL THEN UPDATE episodes SET last_activity_at=clock_timestamp() WHERE id=NEW.episode_id; END IF;
 INSERT INTO notifications(user_id,message) SELECT user_id,'Appointment '||NEW.id||': '||NEW.status FROM patients WHERE id=NEW.patient_id;
 RETURN NULL;
END $$;
CREATE TRIGGER appointment_effects AFTER INSERT OR UPDATE ON appointments FOR EACH ROW EXECUTE FUNCTION appointment_effects();

CREATE FUNCTION protect_note() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE aid bigint; st text; doc bigint;
BEGIN
 IF TG_OP='DELETE' THEN aid:=OLD.appointment_id; ELSE aid:=NEW.appointment_id; END IF;
 IF TG_OP='UPDATE' AND NEW.appointment_id<>OLD.appointment_id THEN RAISE EXCEPTION 'Cannot reassign a note'; END IF;
 SELECT a.status,d.doctor_id INTO st,doc FROM appointments a JOIN time_slots s ON s.id=a.slot_id JOIN doctor_schedules d ON d.id=s.schedule_id WHERE a.id=aid;
 IF st<>'planned' THEN RAISE EXCEPTION 'Only a planned appointment note may be edited'; END IF;
 IF TG_OP<>'DELETE' AND NEW.author_doctor_id<>doc THEN RAISE EXCEPTION 'Note author must be appointment doctor'; END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END $$;
CREATE TRIGGER note_guard BEFORE INSERT OR UPDATE OR DELETE ON medical_notes FOR EACH ROW EXECUTE FUNCTION protect_note();

CREATE FUNCTION append_only() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION '% is append-only',TG_TABLE_NAME; END $$;
CREATE TRIGGER addenda_immutable BEFORE UPDATE OR DELETE ON note_addenda FOR EACH ROW EXECUTE FUNCTION append_only();
CREATE TRIGGER audit_immutable BEFORE UPDATE OR DELETE ON audit_log FOR EACH ROW EXECUTE FUNCTION append_only();

CREATE FUNCTION medical_activity() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE eid bigint; obj jsonb;
BEGIN
 obj:=CASE WHEN TG_OP='DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;
 CASE TG_TABLE_NAME
 WHEN 'care_actions' THEN eid:=(obj->>'episode_id')::bigint;
 WHEN 'study_results' THEN SELECT episode_id INTO eid FROM care_actions WHERE id=(obj->>'care_action_id')::bigint;
 WHEN 'medical_notes' THEN SELECT episode_id INTO eid FROM appointments WHERE id=(obj->>'appointment_id')::bigint;
 WHEN 'note_addenda' THEN SELECT a.episode_id INTO eid FROM medical_notes n JOIN appointments a ON a.id=n.appointment_id WHERE n.id=(obj->>'medical_note_id')::bigint;
 END CASE;
 UPDATE episodes SET last_activity_at=clock_timestamp() WHERE id=eid;
 INSERT INTO audit_log(action,entity_type,entity_id) VALUES(TG_OP,TG_TABLE_NAME,(obj->>'id')::bigint);
 RETURN NULL;
END $$;
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['care_actions','study_results','medical_notes','note_addenda'] LOOP
  EXECUTE format('CREATE TRIGGER activity AFTER INSERT OR UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION medical_activity()',t);
 END LOOP;
END $$;

CREATE FUNCTION validate_state() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF EXISTS(SELECT 1 FROM patients p JOIN users u ON u.id=p.user_id WHERE u.role<>'patient' OR p.birth_date>current_date)
 OR EXISTS(SELECT 1 FROM doctors d JOIN users u ON u.id=d.user_id WHERE u.role<>'doctor') THEN RAISE EXCEPTION 'Invalid profile role or birth date'; END IF;
 IF EXISTS(SELECT 1 FROM time_slots t JOIN doctor_schedules d ON d.id=t.schedule_id WHERE
  (t.starts_at AT TIME ZONE 'Europe/Moscow')::date<>d.work_date OR
  (t.ends_at AT TIME ZONE 'Europe/Moscow')::date<>d.work_date OR
  (t.starts_at AT TIME ZONE 'Europe/Moscow')::time<d.start_time OR
  (t.ends_at AT TIME ZONE 'Europe/Moscow')::time>d.end_time OR
  t.ends_at-t.starts_at<>make_interval(mins=>d.slot_minutes)) THEN RAISE EXCEPTION 'Slot outside schedule or invalid duration'; END IF;
 IF EXISTS(SELECT 1 FROM schedule_breaks b JOIN doctor_schedules d ON d.id=b.schedule_id
  WHERE b.start_time<d.start_time OR b.end_time>d.end_time)
 OR EXISTS(SELECT 1 FROM schedule_breaks b JOIN time_slots t ON t.schedule_id=b.schedule_id JOIN doctor_schedules d ON d.id=b.schedule_id
  WHERE tstzrange(t.starts_at,t.ends_at,'[)') && tstzrange((d.work_date+b.start_time) AT TIME ZONE 'Europe/Moscow',(d.work_date+b.end_time) AT TIME ZONE 'Europe/Moscow','[)'))
 THEN RAISE EXCEPTION 'Invalid break or slot overlaps break'; END IF;
 IF EXISTS(SELECT 1 FROM appointments a JOIN time_slots t ON t.id=a.slot_id WHERE a.starts_at<>t.starts_at OR a.ends_at<>t.ends_at) THEN RAISE EXCEPTION 'Cannot change a slot with appointment history'; END IF;
 IF EXISTS(SELECT 1 FROM doctor_schedules d WHERE
   (SELECT count(*) FROM daily_quotas q WHERE q.schedule_id=d.id)<>3 OR
   (SELECT sum(slot_limit) FROM daily_quotas q WHERE q.schedule_id=d.id)<>(SELECT count(*) FROM time_slots t WHERE t.schedule_id=d.id))
 THEN RAISE EXCEPTION 'Three quotas must sum to schedule slot count'; END IF;
 IF EXISTS(SELECT 1 FROM daily_quotas q JOIN doctor_schedules d ON d.id=q.schedule_id WHERE d.release_at>clock_timestamp() AND
  q.slot_limit < (SELECT count(*) FROM appointments a JOIN time_slots t ON t.id=a.slot_id WHERE t.schedule_id=d.id AND a.booking_type=q.booking_type AND a.status<>'cancelled'))
 THEN RAISE EXCEPTION 'Daily quota exceeded'; END IF;
 IF EXISTS(SELECT 1 FROM appointments a WHERE a.status='held' AND NOT EXISTS(SELECT 1 FROM slot_holds h WHERE h.appointment_id=a.id AND h.status='active'))
 OR EXISTS(SELECT 1 FROM slot_holds h JOIN appointments a ON a.id=h.appointment_id JOIN waitlist_entries w ON w.id=h.waitlist_entry_id JOIN time_slots t ON t.id=a.slot_id JOIN doctor_schedules d ON d.id=t.schedule_id WHERE
  a.patient_id<>w.patient_id OR a.booking_type<>w.booking_type OR a.care_action_id IS DISTINCT FROM w.care_action_id OR d.specialty_id<>w.specialty_id OR a.starts_at<w.preferred_from OR a.ends_at>w.preferred_until OR
  (h.status='active' AND (a.status<>'held' OR w.status<>'offered')) OR
  (h.status IN ('expired','declined') AND a.status<>'cancelled') OR
  (h.status='confirmed' AND a.status='held')) THEN RAISE EXCEPTION 'Hold and appointment mismatch'; END IF;
 IF EXISTS(SELECT 1 FROM medical_notes n JOIN appointments a ON a.id=n.appointment_id JOIN time_slots t ON t.id=a.slot_id JOIN doctor_schedules d ON d.id=t.schedule_id WHERE n.author_doctor_id<>d.doctor_id)
 OR EXISTS(SELECT 1 FROM note_addenda n JOIN medical_notes m ON m.id=n.medical_note_id JOIN appointments a ON a.id=m.appointment_id WHERE a.status<>'completed') THEN RAISE EXCEPTION 'Invalid medical note or addendum'; END IF;
 IF EXISTS(SELECT 1 FROM study_results r JOIN care_actions c ON c.id=r.care_action_id WHERE c.kind<>'study') THEN RAISE EXCEPTION 'Results require a study action'; END IF;
 IF EXISTS(SELECT 1 FROM questionnaire_submissions q JOIN questionnaires f ON f.id=q.questionnaire_id JOIN appointments a ON a.id=q.appointment_id JOIN time_slots t ON t.id=a.slot_id JOIN doctor_schedules d ON d.id=t.schedule_id WHERE f.doctor_id<>d.doctor_id) THEN RAISE EXCEPTION 'Questionnaire belongs to another doctor'; END IF;
 IF EXISTS(SELECT 1 FROM appointments a JOIN care_actions c ON c.id=a.care_action_id JOIN time_slots t ON t.id=a.slot_id JOIN doctor_schedules d ON d.id=t.schedule_id
 WHERE a.booking_type<>c.kind OR c.target_specialty_id<>d.specialty_id OR
 (a.status IN ('held','planned') AND c.status<>'booked') OR (a.status='completed' AND c.status<>'completed')) THEN RAISE EXCEPTION 'Action does not match appointment'; END IF;
 RETURN NULL;
END $$;
DO $$ DECLARE t record; BEGIN
 FOR t IN SELECT tablename FROM pg_tables WHERE schemaname='clinic' AND tablename NOT IN ('audit_log','notifications','system_settings') LOOP
  EXECUTE format('CREATE CONSTRAINT TRIGGER validate_state AFTER INSERT OR UPDATE OR DELETE ON %I DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION validate_state()',t.tablename);
 END LOOP;
END $$;

CREATE FUNCTION protect_schedule() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF EXISTS(SELECT 1 FROM appointments a JOIN time_slots t ON t.id=a.slot_id WHERE t.schedule_id=OLD.id) AND
 ROW(NEW.doctor_id,NEW.specialty_id,NEW.work_date,NEW.start_time,NEW.end_time,NEW.slot_minutes)
 IS DISTINCT FROM ROW(OLD.doctor_id,OLD.specialty_id,OLD.work_date,OLD.start_time,OLD.end_time,OLD.slot_minutes)
 THEN RAISE EXCEPTION 'Schedule with appointment history is immutable; create another day'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER schedule_guard BEFORE UPDATE ON doctor_schedules FOR EACH ROW EXECUTE FUNCTION protect_schedule();

CREATE FUNCTION protect_questionnaire() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE qid bigint;
BEGIN
 IF TG_TABLE_NAME='questions' THEN
  IF TG_OP='INSERT' THEN qid:=NEW.questionnaire_id; ELSE qid:=OLD.questionnaire_id; END IF;
 ELSE qid:=OLD.id;
 END IF;
 IF EXISTS(SELECT 1 FROM questionnaire_submissions WHERE questionnaire_id=qid) THEN
  IF TG_TABLE_NAME='questionnaires' AND TG_OP='UPDATE' THEN
   IF ROW(NEW.doctor_id,NEW.version,NEW.title) IS NOT DISTINCT FROM ROW(OLD.doctor_id,OLD.version,OLD.title) THEN RETURN NEW; END IF;
  END IF;
  RAISE EXCEPTION 'Used questionnaire is immutable; publish a new version';
 END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END $$;
CREATE TRIGGER questionnaire_guard BEFORE UPDATE OR DELETE ON questionnaires FOR EACH ROW EXECUTE FUNCTION protect_questionnaire();
CREATE TRIGGER question_guard BEFORE INSERT OR UPDATE OR DELETE ON questions FOR EACH ROW EXECUTE FUNCTION protect_questionnaire();

CREATE FUNCTION protect_hold() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Keep offer history'; END IF;
 IF TG_OP='UPDATE' THEN
  IF OLD.status<>'active' OR ROW(NEW.appointment_id,NEW.waitlist_entry_id) IS DISTINCT FROM ROW(OLD.appointment_id,OLD.waitlist_entry_id) THEN
   RAISE EXCEPTION 'Offer history is immutable';
  END IF;
  IF NEW.status='confirmed' AND OLD.expires_at<=clock_timestamp() THEN RAISE EXCEPTION 'Offer expired'; END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER hold_guard BEFORE UPDATE OR DELETE ON slot_holds FOR EACH ROW EXECUTE FUNCTION protect_hold();

CREATE FUNCTION prevent_truncate() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'TRUNCATE is disabled; recreate the test database explicitly'; END $$;
DO $$ DECLARE t record; BEGIN
 FOR t IN SELECT tablename FROM pg_tables WHERE schemaname='clinic' LOOP
  EXECUTE format('CREATE TRIGGER prevent_truncate BEFORE TRUNCATE ON %I FOR EACH STATEMENT EXECUTE FUNCTION prevent_truncate()',t.tablename);
 END LOOP;
END $$;
