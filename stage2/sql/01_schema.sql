CREATE SCHEMA clinic;
SET search_path = clinic, public;
CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE TABLE users (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 login text NOT NULL UNIQUE CHECK (length(trim(login)) >= 3),
 password_hash text NOT NULL CHECK (length(password_hash) >= 20),
 role text NOT NULL CHECK (role IN ('patient','doctor','registrar','admin')),
 is_blocked boolean NOT NULL DEFAULT false
);
CREATE TABLE patients (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 user_id bigint NOT NULL UNIQUE REFERENCES users,
 full_name text NOT NULL CHECK (trim(full_name) <> ''), birth_date date NOT NULL,
 oms_number text NOT NULL UNIQUE CHECK (oms_number ~ '^[0-9]{16}$')
);
CREATE TABLE doctors (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 user_id bigint NOT NULL UNIQUE REFERENCES users,
 full_name text NOT NULL CHECK (trim(full_name) <> '')
);
CREATE TABLE specialties (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 name text NOT NULL UNIQUE, self_booking_allowed boolean NOT NULL DEFAULT false
);
CREATE TABLE doctor_specialties (
 doctor_id bigint REFERENCES doctors, specialty_id bigint REFERENCES specialties,
 PRIMARY KEY (doctor_id, specialty_id)
);
CREATE TABLE doctor_schedules (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 doctor_id bigint NOT NULL, specialty_id bigint NOT NULL,
 work_date date NOT NULL, start_time time NOT NULL, end_time time NOT NULL,
 slot_minutes integer NOT NULL CHECK (slot_minutes BETWEEN 5 AND 240),
 release_at timestamptz NOT NULL,
 UNIQUE (doctor_id, work_date), CHECK (start_time < end_time),
 FOREIGN KEY (doctor_id,specialty_id) REFERENCES doctor_specialties
);
CREATE TABLE schedule_breaks (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 schedule_id bigint NOT NULL REFERENCES doctor_schedules,
 start_time time NOT NULL, end_time time NOT NULL, CHECK (start_time < end_time)
);
CREATE TABLE time_slots (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 schedule_id bigint NOT NULL REFERENCES doctor_schedules,
 starts_at timestamptz NOT NULL, ends_at timestamptz NOT NULL,
 CHECK (starts_at < ends_at),
 EXCLUDE USING gist (schedule_id WITH =, tstzrange(starts_at, ends_at, '[)') WITH &&)
);
CREATE TABLE daily_quotas (
 schedule_id bigint REFERENCES doctor_schedules,
 booking_type text CHECK (booking_type IN ('self','referral','followup')),
 slot_limit integer NOT NULL CHECK (slot_limit >= 0),
 PRIMARY KEY (schedule_id,booking_type)
);
CREATE TABLE episodes (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 patient_id bigint NOT NULL REFERENCES patients, title text NOT NULL,
 status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','closed')),
 opened_at timestamptz NOT NULL DEFAULT now(),
 last_activity_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE (id,patient_id)
);
CREATE TABLE care_actions (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 episode_id bigint NOT NULL REFERENCES episodes,
 created_by_doctor_id bigint NOT NULL REFERENCES doctors,
 target_specialty_id bigint REFERENCES specialties,
 kind text NOT NULL CHECK (kind IN ('referral','followup','study')),
 title text NOT NULL,
 status text NOT NULL DEFAULT 'assigned' CHECK (status IN ('assigned','booked','completed','cancelled')),
 CHECK ((kind = 'study') OR target_specialty_id IS NOT NULL),
 UNIQUE (id,episode_id)
);
-- held is an internal reservation state, not an additional public appointment status.
CREATE TABLE appointments (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 patient_id bigint NOT NULL REFERENCES patients,
 slot_id bigint NOT NULL REFERENCES time_slots,
 episode_id bigint, care_action_id bigint,
 created_by_user_id bigint NOT NULL REFERENCES users,
 booking_type text NOT NULL CHECK (booking_type IN ('self','referral','followup')),
 status text NOT NULL DEFAULT 'planned' CHECK (status IN ('held','planned','completed','cancelled','no_show')),
 starts_at timestamptz NOT NULL, ends_at timestamptz NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 CHECK (starts_at < ends_at),
 CHECK ((booking_type = 'self' AND care_action_id IS NULL) OR
        (booking_type <> 'self' AND care_action_id IS NOT NULL AND episode_id IS NOT NULL)),
 FOREIGN KEY (episode_id,patient_id) REFERENCES episodes(id,patient_id),
 FOREIGN KEY (care_action_id,episode_id) REFERENCES care_actions(id,episode_id),
 EXCLUDE USING gist (patient_id WITH =, tstzrange(starts_at,ends_at,'[)') WITH &&)
 WHERE (status IN ('held','planned','completed','no_show'))
);
CREATE UNIQUE INDEX appointment_occupied_slot ON appointments(slot_id) WHERE status <> 'cancelled';
CREATE UNIQUE INDEX appointment_active_action ON appointments(care_action_id) WHERE status IN ('held','planned','completed');
CREATE TABLE waitlist_entries (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 patient_id bigint NOT NULL REFERENCES patients,
 specialty_id bigint NOT NULL REFERENCES specialties,
 care_action_id bigint REFERENCES care_actions,
 booking_type text NOT NULL CHECK (booking_type IN ('self','referral','followup')),
 preferred_from timestamptz NOT NULL, preferred_until timestamptz NOT NULL,
 status text NOT NULL DEFAULT 'waiting' CHECK (status IN ('waiting','offered','accepted','cancelled','expired')),
 created_at timestamptz NOT NULL DEFAULT now(),
 CHECK (preferred_from < preferred_until),
 CHECK ((booking_type='self') = (care_action_id IS NULL))
);
CREATE TABLE slot_holds (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 waitlist_entry_id bigint NOT NULL REFERENCES waitlist_entries,
 appointment_id bigint NOT NULL UNIQUE REFERENCES appointments,
 expires_at timestamptz NOT NULL,
 status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','confirmed','declined','expired'))
);
CREATE UNIQUE INDEX one_offer_per_entry ON slot_holds(waitlist_entry_id) WHERE status='active';
CREATE TABLE notifications (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 user_id bigint NOT NULL REFERENCES users, message text NOT NULL,
 is_read boolean NOT NULL DEFAULT false, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE medical_notes (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 appointment_id bigint NOT NULL UNIQUE REFERENCES appointments,
 author_doctor_id bigint NOT NULL REFERENCES doctors,
 complaints text NOT NULL, examination text NOT NULL, diagnosis text NOT NULL,
 recommendations text NOT NULL
);
CREATE TABLE note_addenda (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 medical_note_id bigint NOT NULL REFERENCES medical_notes,
 doctor_id bigint NOT NULL REFERENCES doctors,
 content text NOT NULL CHECK (trim(content) <> ''), created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE study_results (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 care_action_id bigint NOT NULL REFERENCES care_actions,
 entered_by_doctor_id bigint NOT NULL REFERENCES doctors,
 result_text text NOT NULL, performed_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE questionnaires (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 doctor_id bigint NOT NULL REFERENCES doctors,
 version integer NOT NULL CHECK (version > 0), title text NOT NULL,
 is_active boolean NOT NULL DEFAULT true, UNIQUE(doctor_id,version)
);
CREATE UNIQUE INDEX one_active_questionnaire ON questionnaires(doctor_id) WHERE is_active;
CREATE TABLE questions (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 questionnaire_id bigint NOT NULL REFERENCES questionnaires,
 position integer NOT NULL CHECK (position > 0), question_text text NOT NULL,
 UNIQUE (questionnaire_id,position), UNIQUE(id,questionnaire_id)
);
CREATE TABLE questionnaire_submissions (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 appointment_id bigint NOT NULL UNIQUE REFERENCES appointments,
 questionnaire_id bigint NOT NULL REFERENCES questionnaires,
 submitted_at timestamptz NOT NULL DEFAULT now(), UNIQUE(id,questionnaire_id)
);
CREATE TABLE questionnaire_answers (
 submission_id bigint NOT NULL, question_id bigint NOT NULL,
 questionnaire_id bigint NOT NULL, answer_text text NOT NULL,
 PRIMARY KEY(submission_id,question_id),
 FOREIGN KEY(submission_id,questionnaire_id) REFERENCES questionnaire_submissions(id,questionnaire_id),
 FOREIGN KEY(question_id,questionnaire_id) REFERENCES questions(id,questionnaire_id)
);
CREATE TABLE audit_log (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 db_actor text NOT NULL DEFAULT session_user,
 action text NOT NULL, entity_type text NOT NULL, entity_id bigint,
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE system_settings (
 singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
 hold_minutes integer NOT NULL DEFAULT 30 CHECK (hold_minutes BETWEEN 1 AND 1440),
 inactivity_days integer NOT NULL DEFAULT 60 CHECK (inactivity_days > 0)
);
INSERT INTO system_settings DEFAULT VALUES;
