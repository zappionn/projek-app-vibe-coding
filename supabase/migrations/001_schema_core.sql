-- ============================================================================
-- TeamFair v2.0 - 001_schema_core.sql
-- Core schema for 22 tables, enums, constraints, indexes, and Realtime
-- Target: Supabase PostgreSQL 15+ (Free Tier optimized)
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ----------------------------------------------------------------------------
-- 1. ENUMS
-- ----------------------------------------------------------------------------
CREATE TYPE public.project_status AS ENUM (
  'aktif',
  'angket_berjalan',
  'tinjauan_hak_jawab',
  'selesai'
);

CREATE TYPE public.member_role AS ENUM (
  'ketua',
  'anggota'
);

CREATE TYPE public.intent_category AS ENUM (
  'pending',
  'konsep',
  'riset',
  'desain',
  'koordinasi',
  'basabasi'
);

CREATE TYPE public.attachment_kind AS ENUM (
  'pdf',
  'doc',
  'ppt',
  'link'
);

CREATE TYPE public.attendance_status AS ENUM (
  'hadir',
  'terlambat',
  'tidak_hadir'
);

CREATE TYPE public.logbook_status AS ENUM (
  'draf',
  'pending',
  'sah',
  'sah_bersyarat',
  'ditolak',
  'sengketa'
);

CREATE TYPE public.vote_choice AS ENUM (
  'setuju',
  'tidak_setuju'
);

CREATE TYPE public.flag_status AS ENUM (
  'konsisten',
  'perlu_dicermati',
  'anomali'
);

CREATE TYPE public.activity_component AS ENUM (
  'konseptualisasi',
  'respons',
  'riset_berkas',
  'luring',
  'ketepatan_hadir'
);

CREATE TYPE public.badge_code AS ENUM (
  'the_architect',
  'literature_hunter',
  'visual_crafter',
  'team_anchor'
);

-- ----------------------------------------------------------------------------
-- 2. IDENTITAS & PERANGKAT
-- ----------------------------------------------------------------------------
CREATE TABLE public.users (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email TEXT,
  nama_asli TEXT NOT NULL DEFAULT '',
  npm_nim TEXT NOT NULL DEFAULT '',
  no_whatsapp TEXT,
  is_identity_locked BOOLEAN NOT NULL DEFAULT FALSE,
  consent_uu_pdp_at TIMESTAMPTZ,
  consent_camera_at TIMESTAMPTZ,
  deletion_requested_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE public.device_tokens (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  fcm_token TEXT NOT NULL UNIQUE,
  platform TEXT NOT NULL DEFAULT 'android',
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ----------------------------------------------------------------------------
-- 3. PROYEK & KEANGGOTAAN
-- ----------------------------------------------------------------------------
CREATE TABLE public.projects (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  mata_kuliah TEXT NOT NULL CHECK (char_length(trim(mata_kuliah)) >= 2),
  judul_tugas TEXT NOT NULL CHECK (char_length(trim(judul_tugas)) >= 2),
  deskripsi_tugas TEXT,
  tenggat TIMESTAMPTZ NOT NULL,
  kode_undangan CHAR(6) NOT NULL UNIQUE,
  status public.project_status NOT NULL DEFAULT 'aktif',
  scoring_weights JSONB NOT NULL DEFAULT '{
    "konseptualisasi": 25,
    "respons": 15,
    "riset_berkas": 20,
    "luring": 30,
    "ketepatan_hadir": 10
  }'::jsonb,
  closed_at TIMESTAMPTZ,
  survey_completed_at TIMESTAMPTZ,
  flag_review_deadline TIMESTAMPTZ,
  auto_unlocked_survey BOOLEAN NOT NULL DEFAULT FALSE,
  created_by UUID NOT NULL REFERENCES public.users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE public.memberships (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id UUID NOT NULL REFERENCES public.projects(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  role public.member_role NOT NULL DEFAULT 'anggota',
  color_index SMALLINT NOT NULL CHECK (color_index BETWEEN 0 AND 7),
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  joined_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  left_at TIMESTAMPTZ,
  left_reason TEXT,
  UNIQUE (project_id, user_id),
  UNIQUE (project_id, color_index)
);

CREATE TABLE public.leader_transfer_votes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id UUID NOT NULL REFERENCES public.projects(id) ON DELETE CASCADE,
  target_user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  voter_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (project_id, voter_id)
);

-- ----------------------------------------------------------------------------
-- 4. RUANG KERJA DIGITAL (OBROLAN, BERKAS, AI CO-PILOT)
-- ----------------------------------------------------------------------------
CREATE TABLE public.messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id UUID NOT NULL REFERENCES public.projects(id) ON DELETE CASCADE,
  sender_id UUID NOT NULL REFERENCES public.users(id),
  content TEXT NOT NULL CHECK (char_length(trim(content)) > 0 OR has_attachment),
  has_attachment BOOLEAN NOT NULL DEFAULT FALSE,
  reply_to_id UUID REFERENCES public.messages(id),
  intent_label public.intent_category NOT NULL DEFAULT 'pending',
  intent_score NUMERIC(6, 2) NOT NULL DEFAULT 0,
  commitment_text TEXT,
  commitment_due_at TIMESTAMPTZ,
  commitment_done BOOLEAN NOT NULL DEFAULT FALSE,
  client_recorded_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  server_created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  edited_at TIMESTAMPTZ,
  is_offline_synced BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE public.message_revisions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id UUID NOT NULL REFERENCES public.messages(id) ON DELETE CASCADE,
  previous_content TEXT NOT NULL,
  edited_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE public.attachments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id UUID NOT NULL REFERENCES public.projects(id) ON DELETE CASCADE,
  message_id UUID REFERENCES public.messages(id) ON DELETE SET NULL,
  uploader_id UUID NOT NULL REFERENCES public.users(id),
  kind public.attachment_kind NOT NULL,
  file_name TEXT NOT NULL,
  storage_path TEXT,
  external_url TEXT,
  file_size_bytes BIGINT CHECK (file_size_bytes IS NULL OR file_size_bytes <= 10485760),
  sha256_hash TEXT,
  parent_attachment_id UUID REFERENCES public.attachments(id),
  changelog TEXT,
  extracted_summary TEXT,
  diff_score NUMERIC(6, 2) NOT NULL DEFAULT 1.0,
  is_duplicate BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (storage_path IS NOT NULL OR external_url IS NOT NULL),
  CHECK (parent_attachment_id IS NULL OR char_length(trim(COALESCE(changelog, ''))) >= 20)
);

CREATE TABLE public.task_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id UUID NOT NULL REFERENCES public.projects(id) ON DELETE CASCADE,
  title TEXT NOT NULL CHECK (char_length(trim(title)) >= 2),
  description TEXT,
  claimed_by UUID REFERENCES public.users(id),
  due_at TIMESTAMPTZ,
  is_done BOOLEAN NOT NULL DEFAULT FALSE,
  completed_at TIMESTAMPTZ,
  source TEXT NOT NULL DEFAULT 'ai' CHECK (source IN ('ai', 'manual')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE public.notulen_snapshots (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id UUID NOT NULL REFERENCES public.projects(id) ON DELETE CASCADE,
  summary_md TEXT NOT NULL,
  todos JSONB NOT NULL DEFAULT '[]'::jsonb,
  generated_by UUID REFERENCES public.users(id),
  generated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ----------------------------------------------------------------------------
-- 5. SINKRONISASI LURING (CHECK-IN KAMERA, LOGBOOK, KONSENSUS)
-- ----------------------------------------------------------------------------
CREATE TABLE public.meeting_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id UUID NOT NULL REFERENCES public.projects(id) ON DELETE CASCADE,
  started_by UUID NOT NULL REFERENCES public.users(id),
  location_name TEXT,
  lat DOUBLE PRECISION,
  lng DOUBLE PRECISION,
  started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  ended_at TIMESTAMPTZ,
  duration_minutes INTEGER CHECK (duration_minutes IS NULL OR duration_minutes >= 0)
);

CREATE TABLE public.meeting_photos (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id UUID NOT NULL REFERENCES public.meeting_sessions(id) ON DELETE CASCADE,
  project_id UUID NOT NULL REFERENCES public.projects(id) ON DELETE CASCADE,
  uploaded_by UUID NOT NULL REFERENCES public.users(id),
  storage_path TEXT NOT NULL,
  is_late_batch BOOLEAN NOT NULL DEFAULT FALSE,
  client_recorded_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  server_created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  is_offline_synced BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE public.attendance_records (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id UUID NOT NULL REFERENCES public.meeting_sessions(id) ON DELETE CASCADE,
  photo_id UUID REFERENCES public.meeting_photos(id) ON DELETE SET NULL,
  project_id UUID NOT NULL REFERENCES public.projects(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES public.users(id),
  status public.attendance_status NOT NULL DEFAULT 'hadir',
  late_minutes INTEGER NOT NULL DEFAULT 0 CHECK (late_minutes >= 0),
  tag_box JSONB, -- {"x": 0.25, "y": 0.30, "w": 0.18, "h": 0.22} normalized 0..1
  server_stamped_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (session_id, user_id)
);

CREATE TABLE public.logbook_entries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id UUID NOT NULL REFERENCES public.meeting_sessions(id) ON DELETE CASCADE,
  project_id UUID NOT NULL REFERENCES public.projects(id) ON DELETE CASCADE,
  version SMALLINT NOT NULL DEFAULT 1 CHECK (version BETWEEN 1 AND 2),
  status public.logbook_status NOT NULL DEFAULT 'draf',
  submitted_at TIMESTAMPTZ,
  resolved_at TIMESTAMPTZ,
  created_by UUID NOT NULL REFERENCES public.users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (session_id, version)
);

CREATE TABLE public.logbook_contributions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  entry_id UUID NOT NULL REFERENCES public.logbook_entries(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES public.users(id),
  contribution_text TEXT NOT NULL DEFAULT '',
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (entry_id, user_id)
);

CREATE TABLE public.logbook_votes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  entry_id UUID NOT NULL REFERENCES public.logbook_entries(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES public.users(id),
  vote public.vote_choice NOT NULL,
  reason TEXT,
  server_voted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (entry_id, user_id),
  CHECK (vote = 'setuju' OR char_length(trim(COALESCE(reason, ''))) >= 20)
);

-- ----------------------------------------------------------------------------
-- 6. SKORING, PEER-ASSESSMENT, HAK JAWAB, BADGES, PDF & NOTIFIKASI
-- ----------------------------------------------------------------------------
CREATE TABLE public.activity_metrics (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id UUID NOT NULL REFERENCES public.projects(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES public.users(id),
  component public.activity_component NOT NULL,
  raw_score NUMERIC(8, 2) NOT NULL CHECK (raw_score >= 0),
  source_ref_id UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE public.peer_assessments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id UUID NOT NULL REFERENCES public.projects(id) ON DELETE CASCADE,
  rater_id UUID NOT NULL REFERENCES public.users(id),
  ratee_id UUID NOT NULL REFERENCES public.users(id),
  score SMALLINT NOT NULL CHECK (score BETWEEN 1 AND 4),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (project_id, rater_id, ratee_id)
);

CREATE TABLE public.final_evaluations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id UUID NOT NULL REFERENCES public.projects(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES public.users(id),
  contribution_pct NUMERIC(5, 2) NOT NULL,
  system_score NUMERIC(3, 1) NOT NULL,
  self_score NUMERIC(3, 1),
  peer_avg_score NUMERIC(3, 1),
  flag_status public.flag_status NOT NULL DEFAULT 'konsisten',
  collusion_warning BOOLEAN NOT NULL DEFAULT FALSE,
  right_of_reply TEXT CHECK (right_of_reply IS NULL OR char_length(right_of_reply) <= 200),
  reply_submitted_at TIMESTAMPTZ,
  reply_skipped BOOLEAN NOT NULL DEFAULT FALSE,
  computed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (project_id, user_id)
);

CREATE TABLE public.badge_awards (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id UUID NOT NULL REFERENCES public.projects(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES public.users(id),
  badge_code public.badge_code NOT NULL,
  reason TEXT NOT NULL,
  awarded_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (project_id, user_id, badge_code)
);

CREATE TABLE public.report_snapshots (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id UUID NOT NULL UNIQUE REFERENCES public.projects(id) ON DELETE CASCADE,
  report_code TEXT NOT NULL UNIQUE,
  version INTEGER NOT NULL DEFAULT 1,
  storage_path TEXT NOT NULL,
  hash_sha256 TEXT NOT NULL,
  survey_completion_note TEXT NOT NULL,
  created_by UUID NOT NULL REFERENCES public.users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE public.notifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  project_id UUID REFERENCES public.projects(id) ON DELETE CASCADE,
  type TEXT NOT NULL,
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  is_read BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ----------------------------------------------------------------------------
-- 7. INDEXES (OPTIMASI QUERY & REALTIME)
-- ----------------------------------------------------------------------------
CREATE INDEX idx_memberships_user_active ON public.memberships (user_id, is_active);
CREATE INDEX idx_memberships_project_active ON public.memberships (project_id, is_active);
CREATE INDEX idx_projects_status_tenggat ON public.projects (status, tenggat);
CREATE INDEX idx_messages_project_created ON public.messages (project_id, server_created_at DESC);
CREATE INDEX idx_attachments_project_hash ON public.attachments (project_id, sha256_hash);
CREATE INDEX idx_task_items_project ON public.task_items (project_id, is_done);
CREATE INDEX idx_meeting_sessions_project ON public.meeting_sessions (project_id, started_at DESC);
CREATE INDEX idx_logbook_entries_project_status ON public.logbook_entries (project_id, status);
CREATE INDEX idx_activity_metrics_project_user ON public.activity_metrics (project_id, user_id, component);
CREATE INDEX idx_notifications_user_unread ON public.notifications (user_id, is_read, created_at DESC);

-- ----------------------------------------------------------------------------
-- 8. REALTIME PUBLICATION
-- ----------------------------------------------------------------------------
DO $$
DECLARE
  tbl TEXT;
  tables TEXT[] := ARRAY[
    'projects',
    'memberships',
    'messages',
    'attachments',
    'task_items',
    'logbook_entries',
    'logbook_contributions',
    'logbook_votes',
    'final_evaluations',
    'notifications'
  ];
BEGIN
  FOREACH tbl IN ARRAY tables LOOP
    IF NOT EXISTS (
      SELECT 1
      FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime'
        AND schemaname = 'public'
        AND tablename = tbl
    ) THEN
      EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', tbl);
    END IF;
  END LOOP;
END $$;
