-- ============================================================================
-- TeamFair v2.0 - 003_triggers_and_rpcs.sql
-- Auth triggers, immutable identity/message guards, scoring engine,
-- offline logbook consensus, peer assessment cross-validation, & deadlines
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. AUTH PROFILE SYNC & LOCKED IDENTITY GUARD
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.users (id, email, nama_asli)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'full_name', '')
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_auth_user();

CREATE OR REPLACE FUNCTION public.guard_locked_user_identity()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.is_identity_locked = TRUE THEN
    IF NEW.nama_asli IS DISTINCT FROM OLD.nama_asli
       OR NEW.npm_nim IS DISTINCT FROM OLD.npm_nim
       OR NEW.is_identity_locked IS DISTINCT FROM OLD.is_identity_locked THEN
      RAISE EXCEPTION 'Nama Lengkap dan NPM/NIM sudah terkunci permanen dan tidak dapat diubah.';
    END IF;
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_locked_user_identity ON public.users;
CREATE TRIGGER trg_guard_locked_user_identity
  BEFORE UPDATE ON public.users
  FOR EACH ROW EXECUTE FUNCTION public.guard_locked_user_identity();

CREATE OR REPLACE FUNCTION public.lock_user_identity(
  p_nama_asli TEXT,
  p_npm_nim TEXT,
  p_no_whatsapp TEXT DEFAULT NULL
)
RETURNS public.users
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user public.users;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  IF char_length(trim(COALESCE(p_nama_asli, ''))) < 2 THEN
    RAISE EXCEPTION 'Nama lengkap wajib diisi minimal 2 karakter.';
  END IF;

  IF char_length(trim(COALESCE(p_npm_nim, ''))) < 5 THEN
    RAISE EXCEPTION 'NPM/NIM wajib diisi minimal 5 karakter.';
  END IF;

  SELECT * INTO v_user FROM public.users WHERE id = auth.uid() FOR UPDATE;
  IF NOT FOUND THEN
    INSERT INTO public.users (id) VALUES (auth.uid()) RETURNING * INTO v_user;
  END IF;

  IF v_user.is_identity_locked THEN
    RAISE EXCEPTION 'Identitas akademik sudah dikunci sebelumnya.';
  END IF;

  UPDATE public.users
  SET
    nama_asli = trim(p_nama_asli),
    npm_nim = upper(trim(p_npm_nim)),
    no_whatsapp = NULLIF(trim(COALESCE(p_no_whatsapp, '')), ''),
    is_identity_locked = TRUE,
    consent_uu_pdp_at = COALESCE(consent_uu_pdp_at, now()),
    updated_at = now()
  WHERE id = auth.uid()
  RETURNING * INTO v_user;

  RETURN v_user;
END;
$$;

-- ----------------------------------------------------------------------------
-- 2. MESSAGE EDIT 15-MINUTE GUARD & REVISION LOGGING
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.guard_message_update_and_revision()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_jwt_role TEXT := COALESCE(current_setting('request.jwt.claim.role', TRUE), '');
BEGIN
  -- Allow service_role (Edge Functions) to update AI classification / commitment fields
  IF v_jwt_role = 'service_role' THEN
    RETURN NEW;
  END IF;

  -- Prevent client tampering with immutable fields
  IF NEW.project_id IS DISTINCT FROM OLD.project_id
     OR NEW.sender_id IS DISTINCT FROM OLD.sender_id
     OR NEW.intent_label IS DISTINCT FROM OLD.intent_label
     OR NEW.intent_score IS DISTINCT FROM OLD.intent_score
     OR NEW.server_created_at IS DISTINCT FROM OLD.server_created_at
     OR NEW.client_recorded_at IS DISTINCT FROM OLD.client_recorded_at THEN
    RAISE EXCEPTION 'Kolom sistem pada pesan tidak dapat diubah pengguna.';
  END IF;

  -- Allow marking own commitment done without 15-min limit if content unchanged
  IF NEW.content IS NOT DISTINCT FROM OLD.content THEN
    RETURN NEW;
  END IF;

  IF now() - OLD.server_created_at > interval '15 minutes' THEN
    RAISE EXCEPTION 'Batas waktu edit pesan (15 menit) telah berakhir.';
  END IF;

  INSERT INTO public.message_revisions (message_id, previous_content, edited_at)
  VALUES (OLD.id, OLD.content, now());

  NEW.edited_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_message_update ON public.messages;
CREATE TRIGGER trg_guard_message_update
  BEFORE UPDATE ON public.messages
  FOR EACH ROW EXECUTE FUNCTION public.guard_message_update_and_revision();

-- ----------------------------------------------------------------------------
-- 3. PROJECT CREATION, JOINING (COLOR LOCK), EXTENSION & LEADERSHIP
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.generate_invite_code()
RETURNS CHAR(6)
LANGUAGE plpgsql
AS $$
DECLARE
  v_chars CONSTANT TEXT := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_code TEXT := '';
  i INTEGER;
BEGIN
  LOOP
    v_code := '';
    FOR i IN 1..6 LOOP
      v_code := v_code || substr(v_chars, 1 + floor(random() * length(v_chars))::int, 1);
    END LOOP;
    EXIT WHEN NOT EXISTS (SELECT 1 FROM public.projects WHERE kode_undangan = v_code);
  END LOOP;
  RETURN v_code::CHAR(6);
END;
$$;

CREATE OR REPLACE FUNCTION public.create_project_with_leader(
  p_mata_kuliah TEXT,
  p_judul_tugas TEXT,
  p_tenggat TIMESTAMPTZ,
  p_deskripsi_tugas TEXT DEFAULT NULL
)
RETURNS public.projects
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user public.users;
  v_project public.projects;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  SELECT * INTO v_user FROM public.users WHERE id = auth.uid();
  IF NOT FOUND OR v_user.is_identity_locked = FALSE THEN
    RAISE EXCEPTION 'Lengkapi dan kunci Nama Lengkap & NPM/NIM sebelum membuat ruang kelompok.';
  END IF;

  IF p_tenggat <= now() THEN
    RAISE EXCEPTION 'Batas waktu proyek tidak boleh di masa lalu.';
  END IF;

  INSERT INTO public.projects (
    mata_kuliah, judul_tugas, deskripsi_tugas, tenggat, kode_undangan, created_by
  )
  VALUES (
    trim(p_mata_kuliah),
    trim(p_judul_tugas),
    NULLIF(trim(COALESCE(p_deskripsi_tugas, '')), ''),
    p_tenggat,
    public.generate_invite_code(),
    auth.uid()
  )
  RETURNING * INTO v_project;

  -- Leader always gets color_index = 0 (Biru Pastel)
  INSERT INTO public.memberships (project_id, user_id, role, color_index)
  VALUES (v_project.id, auth.uid(), 'ketua', 0);

  RETURN v_project;
END;
$$;

CREATE OR REPLACE FUNCTION public.join_project_by_code(p_kode TEXT)
RETURNS TABLE (
  project_id UUID,
  mata_kuliah TEXT,
  judul_tugas TEXT,
  color_index SMALLINT,
  role public.member_role
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user public.users;
  v_project public.projects;
  v_existing public.memberships;
  v_next_color SMALLINT;
  v_total_slots INTEGER;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  SELECT * INTO v_user FROM public.users WHERE id = auth.uid();
  IF NOT FOUND OR v_user.is_identity_locked = FALSE THEN
    RAISE EXCEPTION 'Lengkapi dan kunci Nama Lengkap & NPM/NIM sebelum bergabung.';
  END IF;

  SELECT * INTO v_project
  FROM public.projects
  WHERE kode_undangan = upper(trim(p_kode))
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Kode tidak ditemukan.';
  END IF;

  IF v_project.status <> 'aktif' THEN
    RAISE EXCEPTION 'Proyek telah ditutup dan tidak menerima anggota baru.';
  END IF;

  SELECT * INTO v_existing
  FROM public.memberships m
  WHERE m.project_id = v_project.id AND m.user_id = auth.uid();

  IF FOUND THEN
    IF v_existing.is_active THEN
      RETURN QUERY SELECT v_project.id, v_project.mata_kuliah, v_project.judul_tugas, v_existing.color_index, v_existing.role;
      RETURN;
    ELSE
      RAISE EXCEPTION 'Anda sebelumnya tercatat keluar dari proyek ini.';
    END IF;
  END IF;

  SELECT COUNT(*) INTO v_total_slots
  FROM public.memberships m
  WHERE m.project_id = v_project.id;

  IF v_total_slots >= 8 THEN
    RAISE EXCEPTION 'Kapasitas maksimum kelompok (8 warna identitas) sudah penuh.';
  END IF;

  SELECT gs.idx::SMALLINT INTO v_next_color
  FROM generate_series(0, 7) AS gs(idx)
  WHERE NOT EXISTS (
    SELECT 1 FROM public.memberships m
    WHERE m.project_id = v_project.id AND m.color_index = gs.idx
  )
  ORDER BY gs.idx
  LIMIT 1;

  INSERT INTO public.memberships (project_id, user_id, role, color_index)
  VALUES (v_project.id, auth.uid(), 'anggota', v_next_color);

  RETURN QUERY SELECT v_project.id, v_project.mata_kuliah, v_project.judul_tugas, v_next_color, 'anggota'::public.member_role;
END;
$$;

CREATE OR REPLACE FUNCTION public.extend_project_deadline(
  p_project_id UUID,
  p_new_tenggat TIMESTAMPTZ
)
RETURNS public.projects
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_project public.projects;
BEGIN
  IF NOT public.is_project_leader(p_project_id) THEN
    RAISE EXCEPTION 'Hanya ketua kelompok yang dapat memperpanjang tenggat.';
  END IF;
  IF p_new_tenggat <= now() THEN
    RAISE EXCEPTION 'Tenggat baru harus di masa mendatang.';
  END IF;

  UPDATE public.projects
  SET tenggat = p_new_tenggat, updated_at = now()
  WHERE id = p_project_id AND status = 'aktif'
  RETURNING * INTO v_project;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Proyek tidak aktif atau tidak ditemukan.';
  END IF;
  RETURN v_project;
END;
$$;

CREATE OR REPLACE FUNCTION public.exit_or_remove_member(
  p_project_id UUID,
  p_target_user_id UUID,
  p_reason TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_is_leader BOOLEAN := public.is_project_leader(p_project_id);
  v_target public.memberships;
BEGIN
  IF NOT public.is_project_open(p_project_id) THEN
    RAISE EXCEPTION 'Keanggotaan tidak dapat diubah setelah proyek ditutup.';
  END IF;

  IF auth.uid() <> p_target_user_id AND NOT v_caller_is_leader THEN
    RAISE EXCEPTION 'Hanya ketua yang dapat mengeluarkan anggota lain.';
  END IF;

  SELECT * INTO v_target
  FROM public.memberships
  WHERE project_id = p_project_id AND user_id = p_target_user_id AND is_active = TRUE
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Anggota aktif tidak ditemukan.';
  END IF;

  IF v_target.role = 'ketua' THEN
    RAISE EXCEPTION 'Ketua harus mengalihkan peran ketua terlebih dahulu sebelum keluar.';
  END IF;

  UPDATE public.memberships
  SET
    is_active = FALSE,
    left_at = now(),
    left_reason = COALESCE(NULLIF(trim(p_reason), ''), CASE WHEN auth.uid() = p_target_user_id THEN 'Keluar mandiri' ELSE 'Dikeluarkan oleh ketua' END)
  WHERE id = v_target.id;
END;
$$;

CREATE OR REPLACE FUNCTION public.handoff_leadership(
  p_project_id UUID,
  p_new_leader_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_project_leader(p_project_id) THEN
    RAISE EXCEPTION 'Hanya ketua saat ini yang dapat menyerahkan peran ketua.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.memberships
    WHERE project_id = p_project_id AND user_id = p_new_leader_id AND is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'Calon ketua harus merupakan anggota aktif proyek.';
  END IF;

  UPDATE public.memberships SET role = 'anggota'
  WHERE project_id = p_project_id AND role = 'ketua';

  UPDATE public.memberships SET role = 'ketua'
  WHERE project_id = p_project_id AND user_id = p_new_leader_id;

  DELETE FROM public.leader_transfer_votes WHERE project_id = p_project_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.vote_transfer_leader(
  p_project_id UUID,
  p_target_user_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_active_count INTEGER;
  v_vote_count INTEGER;
BEGIN
  IF NOT public.is_active_project_member(p_project_id) OR NOT public.is_project_open(p_project_id) THEN
    RAISE EXCEPTION 'Hanya anggota aktif pada proyek aktif yang dapat memilih.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.memberships
    WHERE project_id = p_project_id AND user_id = p_target_user_id AND is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'Target calon ketua bukan anggota aktif.';
  END IF;

  INSERT INTO public.leader_transfer_votes (project_id, target_user_id, voter_id)
  VALUES (p_project_id, p_target_user_id, auth.uid())
  ON CONFLICT (project_id, voter_id)
  DO UPDATE SET target_user_id = EXCLUDED.target_user_id, created_at = now();

  SELECT COUNT(*) INTO v_active_count
  FROM public.memberships WHERE project_id = p_project_id AND is_active = TRUE;

  SELECT COUNT(*) INTO v_vote_count
  FROM public.leader_transfer_votes
  WHERE project_id = p_project_id AND target_user_id = p_target_user_id;

  IF v_vote_count > (v_active_count / 2.0) THEN
    UPDATE public.memberships SET role = 'anggota'
    WHERE project_id = p_project_id AND role = 'ketua';

    UPDATE public.memberships SET role = 'ketua'
    WHERE project_id = p_project_id AND user_id = p_target_user_id;

    DELETE FROM public.leader_transfer_votes WHERE project_id = p_project_id;
    RETURN TRUE;
  END IF;

  RETURN FALSE;
END;
$$;

-- ----------------------------------------------------------------------------
-- 4. LOGBOOK PERTEMUAN LURING & KONSENSUS
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.finish_meeting_and_init_logbook(p_session_id UUID)
RETURNS public.logbook_entries
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_session public.meeting_sessions;
  v_entry public.logbook_entries;
  v_duration INTEGER;
BEGIN
  SELECT * INTO v_session FROM public.meeting_sessions WHERE id = p_session_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Sesi pertemuan tidak ditemukan.';
  END IF;
  IF NOT public.is_project_leader(v_session.project_id) THEN
    RAISE EXCEPTION 'Hanya ketua yang dapat menyelesaikan pertemuan.';
  END IF;

  IF v_session.ended_at IS NULL THEN
    v_duration := GREATEST(1, FLOOR(EXTRACT(EPOCH FROM (now() - v_session.started_at)) / 60)::INTEGER);
    UPDATE public.meeting_sessions
    SET ended_at = now(), duration_minutes = v_duration
    WHERE id = p_session_id
    RETURNING * INTO v_session;
  END IF;

  SELECT * INTO v_entry FROM public.logbook_entries
  WHERE session_id = p_session_id AND version = 1;

  IF NOT FOUND THEN
    INSERT INTO public.logbook_entries (session_id, project_id, version, status, created_by)
    VALUES (p_session_id, v_session.project_id, 1, 'draf', auth.uid())
    RETURNING * INTO v_entry;

    INSERT INTO public.logbook_contributions (entry_id, user_id, contribution_text)
    SELECT v_entry.id, m.user_id, ''
    FROM public.memberships m
    WHERE m.project_id = v_session.project_id AND m.is_active = TRUE;
  END IF;

  RETURN v_entry;
END;
$$;

CREATE OR REPLACE FUNCTION public.submit_logbook_entry(p_entry_id UUID)
RETURNS public.logbook_entries
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_entry public.logbook_entries;
BEGIN
  SELECT * INTO v_entry FROM public.logbook_entries WHERE id = p_entry_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Entri logbook tidak ditemukan.';
  END IF;
  IF NOT public.is_project_leader(v_entry.project_id) THEN
    RAISE EXCEPTION 'Hanya ketua yang dapat mengirim laporan logbook.';
  END IF;
  IF v_entry.status <> 'draf' THEN
    RAISE EXCEPTION 'Logbook sudah dikirim sebelumnya.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.logbook_contributions lc
    WHERE lc.entry_id = p_entry_id AND char_length(trim(lc.contribution_text)) = 0
  ) THEN
    RAISE EXCEPTION 'Semua kolom Kontribusi Hari Ini untuk anggota aktif harus diisi.';
  END IF;

  UPDATE public.logbook_entries
  SET status = 'pending', submitted_at = now()
  WHERE id = p_entry_id
  RETURNING * INTO v_entry;

  -- Leader automatically votes 'setuju' upon submission
  INSERT INTO public.logbook_votes (entry_id, user_id, vote)
  VALUES (p_entry_id, auth.uid(), 'setuju')
  ON CONFLICT (entry_id, user_id) DO NOTHING;

  -- If group only has 1 active member, auto-approve immediately
  PERFORM public.evaluate_logbook_consensus(p_entry_id);
  SELECT * INTO v_entry FROM public.logbook_entries WHERE id = p_entry_id;
  RETURN v_entry;
END;
$$;

CREATE OR REPLACE FUNCTION public.evaluate_logbook_consensus(p_entry_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_entry public.logbook_entries;
  v_session public.meeting_sessions;
  v_active_count INTEGER;
  v_agree_count INTEGER;
  v_disagree_count INTEGER;
BEGIN
  SELECT * INTO v_entry FROM public.logbook_entries WHERE id = p_entry_id FOR UPDATE;
  IF NOT FOUND OR v_entry.status <> 'pending' THEN
    RETURN;
  END IF;

  SELECT COUNT(*) INTO v_disagree_count
  FROM public.logbook_votes WHERE entry_id = p_entry_id AND vote = 'tidak_setuju';

  IF v_disagree_count > 0 THEN
    UPDATE public.logbook_entries
    SET
      status = CASE WHEN v_entry.version >= 2 THEN 'sengketa'::public.logbook_status ELSE 'ditolak'::public.logbook_status END,
      resolved_at = CASE WHEN v_entry.version >= 2 THEN now() ELSE NULL END
    WHERE id = p_entry_id;
    RETURN;
  END IF;

  SELECT COUNT(*) INTO v_active_count
  FROM public.memberships WHERE project_id = v_entry.project_id AND is_active = TRUE;

  SELECT COUNT(*) INTO v_agree_count
  FROM public.logbook_votes lv
  JOIN public.memberships m ON m.project_id = v_entry.project_id AND m.user_id = lv.user_id AND m.is_active = TRUE
  WHERE lv.entry_id = p_entry_id AND lv.vote = 'setuju';

  IF v_agree_count >= v_active_count THEN
    UPDATE public.logbook_entries
    SET status = 'sah', resolved_at = now()
    WHERE id = p_entry_id;

    -- Record validated offline contribution & punctuality metrics
    SELECT * INTO v_session FROM public.meeting_sessions WHERE id = v_entry.session_id;
    PERFORM public.record_verified_meeting_metrics(v_entry.id, v_session.project_id, v_session.id, COALESCE(v_session.duration_minutes, 60));
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.record_verified_meeting_metrics(
  p_entry_id UUID,
  p_project_id UUID,
  p_session_id UUID,
  p_duration_minutes INTEGER
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rec RECORD;
  v_luring_pts NUMERIC(8,2);
  v_punctuality_pts NUMERIC(8,2);
BEGIN
  -- Idempotent guard per entry
  IF EXISTS (
    SELECT 1 FROM public.activity_metrics
    WHERE source_ref_id = p_entry_id AND component IN ('luring', 'ketepatan_hadir')
  ) THEN
    RETURN;
  END IF;

  FOR v_rec IN
    SELECT
      lc.user_id,
      lc.contribution_text,
      COALESCE(ar.status, 'tidak_hadir'::public.attendance_status) AS att_status,
      COALESCE(ar.late_minutes, 0) AS late_minutes
    FROM public.logbook_contributions lc
    LEFT JOIN public.attendance_records ar
      ON ar.session_id = p_session_id AND ar.user_id = lc.user_id
    WHERE lc.entry_id = p_entry_id
  LOOP
    IF v_rec.att_status IN ('hadir', 'terlambat') THEN
      v_luring_pts := GREATEST(10.0, LEAST(120.0, p_duration_minutes::numeric)) / 30.0
                      * CASE WHEN char_length(trim(v_rec.contribution_text)) > 10 THEN 1.0 ELSE 0.5 END;
      v_punctuality_pts := CASE
        WHEN v_rec.att_status = 'hadir' THEN 10.0
        WHEN v_rec.late_minutes <= 15 THEN 7.0
        WHEN v_rec.late_minutes <= 30 THEN 5.0
        ELSE 3.0
      END;
    ELSE
      v_luring_pts := 0.0;
      v_punctuality_pts := 0.0;
    END IF;

    IF v_luring_pts > 0 THEN
      INSERT INTO public.activity_metrics (project_id, user_id, component, raw_score, source_ref_id)
      VALUES (p_project_id, v_rec.user_id, 'luring', round(v_luring_pts, 2), p_entry_id);
    END IF;

    IF v_punctuality_pts > 0 THEN
      INSERT INTO public.activity_metrics (project_id, user_id, component, raw_score, source_ref_id)
      VALUES (p_project_id, v_rec.user_id, 'ketepatan_hadir', round(v_punctuality_pts, 2), p_entry_id);
    END IF;
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION public.submit_logbook_vote(
  p_entry_id UUID,
  p_vote public.vote_choice,
  p_reason TEXT DEFAULT NULL
)
RETURNS public.logbook_entries
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_entry public.logbook_entries;
BEGIN
  SELECT * INTO v_entry FROM public.logbook_entries WHERE id = p_entry_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Logbook tidak ditemukan.';
  END IF;
  IF NOT public.is_active_project_member(v_entry.project_id) THEN
    RAISE EXCEPTION 'Hanya anggota aktif yang dapat memvalidasi logbook.';
  END IF;
  IF v_entry.status <> 'pending' THEN
    RAISE EXCEPTION 'Logbook tidak sedang menunggu persetujuan.';
  END IF;
  IF p_vote = 'tidak_setuju' AND char_length(trim(COALESCE(p_reason, ''))) < 20 THEN
    RAISE EXCEPTION 'Alasan penolakan wajib diisi minimal 20 karakter.';
  END IF;

  INSERT INTO public.logbook_votes (entry_id, user_id, vote, reason)
  VALUES (p_entry_id, auth.uid(), p_vote, NULLIF(trim(COALESCE(p_reason, '')), ''))
  ON CONFLICT (entry_id, user_id)
  DO UPDATE SET vote = EXCLUDED.vote, reason = EXCLUDED.reason, server_voted_at = now();

  PERFORM public.evaluate_logbook_consensus(p_entry_id);
  SELECT * INTO v_entry FROM public.logbook_entries WHERE id = p_entry_id;
  RETURN v_entry;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_logbook_revision(p_session_id UUID)
RETURNS public.logbook_entries
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_prev public.logbook_entries;
  v_new public.logbook_entries;
BEGIN
  SELECT * INTO v_prev
  FROM public.logbook_entries
  WHERE session_id = p_session_id
  ORDER BY version DESC
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND OR v_prev.status <> 'ditolak' THEN
    RAISE EXCEPTION 'Revisi hanya dapat dibuat dari logbook berstatus ditolak.';
  END IF;
  IF NOT public.is_project_leader(v_prev.project_id) THEN
    RAISE EXCEPTION 'Hanya ketua yang dapat membuat revisi logbook.';
  END IF;
  IF v_prev.version >= 2 THEN
    RAISE EXCEPTION 'Batas revisi maksimal (2 versi) telah tercapai.';
  END IF;

  INSERT INTO public.logbook_entries (session_id, project_id, version, status, created_by)
  VALUES (p_session_id, v_prev.project_id, 2, 'draf', auth.uid())
  RETURNING * INTO v_new;

  INSERT INTO public.logbook_contributions (entry_id, user_id, contribution_text)
  SELECT v_new.id, lc.user_id, lc.contribution_text
  FROM public.logbook_contributions lc
  WHERE lc.entry_id = v_prev.id;

  RETURN v_new;
END;
$$;

-- ----------------------------------------------------------------------------
-- 5. SCORING ENGINE (LIVE ANALYTICS & PROPORTIONAL RE-WEIGHTING)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.calculate_project_analytics(p_project_id UUID)
RETURNS TABLE (
  user_id UUID,
  nama_asli TEXT,
  npm_nim TEXT,
  color_index SMALLINT,
  role public.member_role,
  is_active BOOLEAN,
  konseptualisasi_raw NUMERIC,
  respons_raw NUMERIC,
  riset_berkas_raw NUMERIC,
  luring_raw NUMERIC,
  ketepatan_hadir_raw NUMERIC,
  contribution_pct NUMERIC,
  ratio NUMERIC,
  system_score NUMERIC
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_weights JSONB;
  v_w_konsep NUMERIC;
  v_w_respons NUMERIC;
  v_w_riset NUMERIC;
  v_w_luring NUMERIC;
  v_w_hadir NUMERIC;
  v_active_count INTEGER;
  v_sum_konsep NUMERIC;
  v_sum_respons NUMERIC;
  v_sum_riset NUMERIC;
  v_sum_luring NUMERIC;
  v_sum_hadir NUMERIC;
  v_active_weight_sum NUMERIC := 0;
  v_balanced_share NUMERIC;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_project_member(p_project_id) THEN
    RAISE EXCEPTION 'Access denied';
  END IF;

  SELECT scoring_weights INTO v_weights FROM public.projects WHERE id = p_project_id;
  v_w_konsep  := COALESCE((v_weights->>'konseptualisasi')::numeric, 25);
  v_w_respons := COALESCE((v_weights->>'respons')::numeric, 15);
  v_w_riset   := COALESCE((v_weights->>'riset_berkas')::numeric, 20);
  v_w_luring  := COALESCE((v_weights->>'luring')::numeric, 30);
  v_w_hadir   := COALESCE((v_weights->>'ketepatan_hadir')::numeric, 10);

  SELECT COUNT(*) INTO v_active_count
  FROM public.memberships m WHERE m.project_id = p_project_id AND m.is_active = TRUE;
  v_balanced_share := CASE WHEN v_active_count > 0 THEN 100.0 / v_active_count ELSE 100.0 END;

  SELECT
    COALESCE(SUM(CASE WHEN am.component = 'konseptualisasi' THEN am.raw_score ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN am.component = 'respons' THEN am.raw_score ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN am.component = 'riset_berkas' THEN am.raw_score ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN am.component = 'luring' THEN am.raw_score ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN am.component = 'ketepatan_hadir' THEN am.raw_score ELSE 0 END), 0)
  INTO v_sum_konsep, v_sum_respons, v_sum_riset, v_sum_luring, v_sum_hadir
  FROM public.activity_metrics am
  JOIN public.memberships m ON m.project_id = am.project_id AND m.user_id = am.user_id AND m.is_active = TRUE
  WHERE am.project_id = p_project_id;

  IF v_sum_konsep > 0 THEN v_active_weight_sum := v_active_weight_sum + v_w_konsep; END IF;
  IF v_sum_respons > 0 THEN v_active_weight_sum := v_active_weight_sum + v_w_respons; END IF;
  IF v_sum_riset > 0 THEN v_active_weight_sum := v_active_weight_sum + v_w_riset; END IF;
  IF v_sum_luring > 0 THEN v_active_weight_sum := v_active_weight_sum + v_w_luring; END IF;
  IF v_sum_hadir > 0 THEN v_active_weight_sum := v_active_weight_sum + v_w_hadir; END IF;

  RETURN QUERY
  WITH per_member AS (
    SELECT
      m.user_id,
      u.nama_asli,
      u.npm_nim,
      m.color_index,
      m.role,
      m.is_active,
      COALESCE(SUM(CASE WHEN am.component = 'konseptualisasi' THEN am.raw_score ELSE 0 END), 0) AS c_konsep,
      COALESCE(SUM(CASE WHEN am.component = 'respons' THEN am.raw_score ELSE 0 END), 0) AS c_respons,
      COALESCE(SUM(CASE WHEN am.component = 'riset_berkas' THEN am.raw_score ELSE 0 END), 0) AS c_riset,
      COALESCE(SUM(CASE WHEN am.component = 'luring' THEN am.raw_score ELSE 0 END), 0) AS c_luring,
      COALESCE(SUM(CASE WHEN am.component = 'ketepatan_hadir' THEN am.raw_score ELSE 0 END), 0) AS c_hadir
    FROM public.memberships m
    JOIN public.users u ON u.id = m.user_id
    LEFT JOIN public.activity_metrics am ON am.project_id = m.project_id AND am.user_id = m.user_id
    WHERE m.project_id = p_project_id
    GROUP BY m.user_id, u.nama_asli, u.npm_nim, m.color_index, m.role, m.is_active
  ),
  pct_calc AS (
    SELECT
      pm.*,
      CASE
        WHEN NOT pm.is_active OR v_active_weight_sum = 0 THEN 0.0
        ELSE round((
          (CASE WHEN v_sum_konsep > 0 THEN (v_w_konsep / v_active_weight_sum) * (pm.c_konsep / v_sum_konsep) ELSE 0 END) +
          (CASE WHEN v_sum_respons > 0 THEN (v_w_respons / v_active_weight_sum) * (pm.c_respons / v_sum_respons) ELSE 0 END) +
          (CASE WHEN v_sum_riset > 0 THEN (v_w_riset / v_active_weight_sum) * (pm.c_riset / v_sum_riset) ELSE 0 END) +
          (CASE WHEN v_sum_luring > 0 THEN (v_w_luring / v_active_weight_sum) * (pm.c_luring / v_sum_luring) ELSE 0 END) +
          (CASE WHEN v_sum_hadir > 0 THEN (v_w_hadir / v_active_weight_sum) * (pm.c_hadir / v_sum_hadir) ELSE 0 END)
        ) * 100.0, 2)
      END AS pct
    FROM per_member pm
  )
  SELECT
    pc.user_id,
    pc.nama_asli,
    pc.npm_nim,
    pc.color_index,
    pc.role,
    pc.is_active,
    pc.c_konsep,
    pc.c_respons,
    pc.c_riset,
    pc.c_luring,
    pc.c_hadir,
    pc.pct,
    CASE WHEN pc.is_active THEN round(pc.pct / v_balanced_share, 2) ELSE 0.0 END AS calc_ratio,
    CASE
      WHEN NOT pc.is_active THEN 1.0
      ELSE round(1.0 + 3.0 * LEAST(1.0, pc.pct / v_balanced_share), 1)
    END AS calc_sys_score
  FROM pct_calc pc
  ORDER BY pc.is_active DESC, pc.color_index ASC;
END;
$$;

-- ----------------------------------------------------------------------------
-- 6. CLOSURE, PEER ASSESSMENT, CROSS-VALIDATION, HAK JAWAB & PDF SNAPSHOT
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.close_project(p_project_id UUID)
RETURNS public.projects
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_project public.projects;
BEGIN
  IF NOT public.is_project_leader(p_project_id) THEN
    RAISE EXCEPTION 'Hanya ketua yang dapat menutup proyek.';
  END IF;

  UPDATE public.projects
  SET status = 'angket_berjalan', closed_at = now(), updated_at = now()
  WHERE id = p_project_id AND status = 'aktif'
  RETURNING * INTO v_project;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Proyek sudah ditutup atau tidak ditemukan.';
  END IF;
  RETURN v_project;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_survey_progress(p_project_id UUID)
RETURNS TABLE (
  completed_members INTEGER,
  total_active_members INTEGER,
  has_caller_submitted BOOLEAN
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_total INTEGER;
  v_done INTEGER;
  v_caller_done BOOLEAN;
BEGIN
  IF NOT public.is_project_member(p_project_id) THEN
    RAISE EXCEPTION 'Access denied';
  END IF;

  SELECT COUNT(*) INTO v_total
  FROM public.memberships WHERE project_id = p_project_id AND is_active = TRUE;

  SELECT COUNT(*) INTO v_done
  FROM (
    SELECT pa.rater_id
    FROM public.peer_assessments pa
    JOIN public.memberships m ON m.project_id = pa.project_id AND m.user_id = pa.rater_id AND m.is_active = TRUE
    WHERE pa.project_id = p_project_id
    GROUP BY pa.rater_id
    HAVING COUNT(DISTINCT pa.ratee_id) >= v_total
  ) sub;

  SELECT EXISTS (
    SELECT 1 FROM public.peer_assessments
    WHERE project_id = p_project_id AND rater_id = auth.uid()
  ) INTO v_caller_done;

  RETURN QUERY SELECT v_done, v_total, v_caller_done;
END;
$$;

CREATE OR REPLACE FUNCTION public.finalize_survey_and_flags(
  p_project_id UUID,
  p_is_auto_unlock BOOLEAN DEFAULT FALSE
)
RETURNS public.projects
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_project public.projects;
  v_rec RECORD;
  v_self_score NUMERIC(3,1);
  v_peer_avg NUMERIC(3,1);
  v_diff_peer NUMERIC;
  v_diff_sys NUMERIC;
  v_flag public.flag_status;
  v_has_any_flag BOOLEAN := FALSE;
  v_all_uniform_high BOOLEAN := FALSE;
  v_min_pct NUMERIC;
  v_active_cnt INTEGER;
  v_min_rating INTEGER;
  v_avg_rating NUMERIC;
BEGIN
  SELECT * INTO v_project FROM public.projects WHERE id = p_project_id FOR UPDATE;
  IF NOT FOUND OR v_project.status <> 'angket_berjalan' THEN
    RETURN v_project;
  END IF;

  SELECT COUNT(*) INTO v_active_cnt
  FROM public.memberships WHERE project_id = p_project_id AND is_active = TRUE;

  -- Collusion check: uniformly high peer scores despite skewed contribution
  SELECT MIN(score), AVG(score) INTO v_min_rating, v_avg_rating
  FROM public.peer_assessments WHERE project_id = p_project_id;

  SELECT MIN(a.contribution_pct) INTO v_min_pct
  FROM public.calculate_project_analytics(p_project_id) a
  WHERE a.is_active = TRUE;

  IF v_active_cnt > 1 AND v_min_rating = 4 AND v_avg_rating >= 3.8
     AND COALESCE(v_min_pct, 100) < (0.5 * (100.0 / v_active_cnt)) THEN
    v_all_uniform_high := TRUE;
  END IF;

  FOR v_rec IN
    SELECT * FROM public.calculate_project_analytics(p_project_id) a
    WHERE a.is_active = TRUE
  LOOP
    SELECT score::numeric(3,1) INTO v_self_score
    FROM public.peer_assessments
    WHERE project_id = p_project_id AND rater_id = v_rec.user_id AND ratee_id = v_rec.user_id;

    SELECT round(AVG(score)::numeric, 1) INTO v_peer_avg
    FROM public.peer_assessments
    WHERE project_id = p_project_id AND ratee_id = v_rec.user_id AND rater_id <> v_rec.user_id;

    v_flag := 'konsisten';
    IF v_self_score IS NOT NULL AND v_peer_avg IS NOT NULL THEN
      v_diff_peer := v_self_score - v_peer_avg;
      v_diff_sys := v_self_score - v_rec.system_score;

      IF v_diff_peer >= 2.0 AND v_diff_sys >= 2.0 THEN
        v_flag := 'anomali';
        v_has_any_flag := TRUE;
      ELSIF v_diff_peer >= 1.0 OR v_diff_sys >= 1.0 THEN
        v_flag := 'perlu_dicermati';
        v_has_any_flag := TRUE;
      END IF;
    ELSIF v_self_score IS NOT NULL THEN
      IF (v_self_score - v_rec.system_score) >= 2.0 THEN
        v_flag := 'perlu_dicermati';
        v_has_any_flag := TRUE;
      END IF;
    END IF;

    INSERT INTO public.final_evaluations (
      project_id, user_id, contribution_pct, system_score, self_score, peer_avg_score, flag_status, collusion_warning
    )
    VALUES (
      p_project_id, v_rec.user_id, v_rec.contribution_pct, v_rec.system_score, v_self_score, v_peer_avg, v_flag, v_all_uniform_high
    )
    ON CONFLICT (project_id, user_id) DO UPDATE SET
      contribution_pct = EXCLUDED.contribution_pct,
      system_score = EXCLUDED.system_score,
      self_score = EXCLUDED.self_score,
      peer_avg_score = EXCLUDED.peer_avg_score,
      flag_status = EXCLUDED.flag_status,
      collusion_warning = EXCLUDED.collusion_warning,
      computed_at = now();
  END LOOP;

  UPDATE public.projects
  SET
    survey_completed_at = now(),
    auto_unlocked_survey = p_is_auto_unlock,
    status = CASE WHEN v_has_any_flag THEN 'tinjauan_hak_jawab'::public.project_status ELSE 'selesai'::public.project_status END,
    flag_review_deadline = CASE WHEN v_has_any_flag THEN now() + interval '12 hours' ELSE NULL END,
    updated_at = now()
  WHERE id = p_project_id
  RETURNING * INTO v_project;

  RETURN v_project;
END;
$$;

CREATE OR REPLACE FUNCTION public.submit_peer_assessment(
  p_project_id UUID,
  p_ratings JSONB -- [{"ratee_id": "...", "score": 4}, ...]
)
RETURNS public.projects
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_project public.projects;
  v_active_cnt INTEGER;
  v_item JSONB;
  v_ratee UUID;
  v_score INTEGER;
  v_prog RECORD;
BEGIN
  IF NOT public.is_active_project_member(p_project_id) THEN
    RAISE EXCEPTION 'Hanya anggota aktif yang dapat mengisi angket.';
  END IF;

  SELECT * INTO v_project FROM public.projects WHERE id = p_project_id;
  IF NOT FOUND OR v_project.status <> 'angket_berjalan' THEN
    RAISE EXCEPTION 'Angket sedang tidak dibuka.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.peer_assessments
    WHERE project_id = p_project_id AND rater_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Anda sudah mengirimkan angket penilaian sejawat.';
  END IF;

  SELECT COUNT(*) INTO v_active_cnt
  FROM public.memberships WHERE project_id = p_project_id AND is_active = TRUE;

  IF jsonb_array_length(p_ratings) <> v_active_cnt THEN
    RAISE EXCEPTION 'Wajib menilai diri sendiri dan seluruh % anggota aktif.', v_active_cnt;
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_ratings) LOOP
    v_ratee := (v_item->>'ratee_id')::UUID;
    v_score := (v_item->>'score')::INTEGER;

    IF v_score NOT BETWEEN 1 AND 4 THEN
      RAISE EXCEPTION 'Skor penilaian wajib bernilai 1 sampai 4.';
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM public.memberships
      WHERE project_id = p_project_id AND user_id = v_ratee AND is_active = TRUE
    ) THEN
      RAISE EXCEPTION 'Target anggota tidak valid.';
    END IF;

    INSERT INTO public.peer_assessments (project_id, rater_id, ratee_id, score)
    VALUES (p_project_id, auth.uid(), v_ratee, v_score);
  END LOOP;

  SELECT * INTO v_prog FROM public.get_survey_progress(p_project_id);
  IF v_prog.completed_members >= v_prog.total_active_members THEN
    SELECT * INTO v_project FROM public.finalize_survey_and_flags(p_project_id, FALSE);
  END IF;

  RETURN v_project;
END;
$$;

CREATE OR REPLACE FUNCTION public.submit_right_of_reply(
  p_project_id UUID,
  p_reply_text TEXT DEFAULT NULL,
  p_skip BOOLEAN DEFAULT FALSE
)
RETURNS public.projects
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_project public.projects;
  v_eval public.final_evaluations;
  v_pending_flagged INTEGER;
BEGIN
  SELECT * INTO v_project FROM public.projects WHERE id = p_project_id FOR UPDATE;
  IF NOT FOUND OR v_project.status <> 'tinjauan_hak_jawab' THEN
    RAISE EXCEPTION 'Tahap Tinjauan Hak Jawab sedang tidak aktif.';
  END IF;

  SELECT * INTO v_eval FROM public.final_evaluations
  WHERE project_id = p_project_id AND user_id = auth.uid() FOR UPDATE;

  IF NOT FOUND OR v_eval.flag_status = 'konsisten' THEN
    RAISE EXCEPTION 'Hak Jawab hanya tersedia bagi anggota berstatus Perlu dicermati atau Anomali.';
  END IF;

  IF NOT p_skip THEN
    IF char_length(trim(COALESCE(p_reply_text, ''))) = 0 OR char_length(trim(p_reply_text)) > 200 THEN
      RAISE EXCEPTION 'Klarifikasi Hak Jawab harus 1 sampai 200 karakter.';
    END IF;
    UPDATE public.final_evaluations
    SET right_of_reply = trim(p_reply_text), reply_submitted_at = now(), reply_skipped = FALSE
    WHERE id = v_eval.id;
  ELSE
    UPDATE public.final_evaluations
    SET reply_skipped = TRUE, reply_submitted_at = now()
    WHERE id = v_eval.id;
  END IF;

  SELECT COUNT(*) INTO v_pending_flagged
  FROM public.final_evaluations
  WHERE project_id = p_project_id
    AND flag_status IN ('perlu_dicermati', 'anomali')
    AND reply_submitted_at IS NULL;

  IF v_pending_flagged = 0 THEN
    UPDATE public.projects
    SET status = 'selesai', updated_at = now()
    WHERE id = p_project_id
    RETURNING * INTO v_project;
  END IF;

  RETURN v_project;
END;
$$;

CREATE OR REPLACE FUNCTION public.register_report_snapshot(
  p_project_id UUID,
  p_storage_path TEXT,
  p_hash_sha256 TEXT
)
RETURNS public.report_snapshots
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_project public.projects;
  v_existing public.report_snapshots;
  v_snapshot public.report_snapshots;
  v_total_active INTEGER;
  v_done INTEGER;
  v_note TEXT;
  v_code TEXT;
BEGIN
  IF NOT public.is_project_member(p_project_id) THEN
    RAISE EXCEPTION 'Access denied';
  END IF;

  SELECT * INTO v_project FROM public.projects WHERE id = p_project_id FOR UPDATE;
  IF v_project.status <> 'selesai' THEN
    RAISE EXCEPTION 'Laporan PDF Master baru dapat dikunci setelah tahap angket & hak jawab selesai.';
  END IF;

  SELECT * INTO v_existing FROM public.report_snapshots WHERE project_id = p_project_id;
  IF FOUND THEN
    RETURN v_existing;
  END IF;

  SELECT COUNT(*) INTO v_total_active
  FROM public.memberships WHERE project_id = p_project_id AND is_active = TRUE;

  SELECT COUNT(*) INTO v_done
  FROM (
    SELECT rater_id FROM public.peer_assessments
    WHERE project_id = p_project_id
    GROUP BY rater_id
    HAVING COUNT(DISTINCT ratee_id) >= v_total_active
  ) s;

  IF v_project.auto_unlocked_survey THEN
    v_note := format('Angket Tidak Lengkap (%s dari %s anggota; Auto-Unlock 48 jam)', v_done, v_total_active);
  ELSE
    v_note := format('Telah Divalidasi (%s dari %s anggota mengisi angket)', v_done, v_total_active);
  END IF;

  v_code := 'TF-' || to_char(now(), 'YYYY') || '-' || upper(substr(replace(p_project_id::text, '-', ''), 1, 6));

  INSERT INTO public.report_snapshots (
    project_id, report_code, version, storage_path, hash_sha256, survey_completion_note, created_by
  )
  VALUES (
    p_project_id, v_code, 1, p_storage_path, p_hash_sha256, v_note, auth.uid()
  )
  RETURNING * INTO v_snapshot;

  RETURN v_snapshot;
END;
$$;

-- ----------------------------------------------------------------------------
-- 7. IDEMPOTENT DEADLINE SWEEP (72h LOGBOOK, TENTATIF CLOSURE, 48h SURVEY, 12h REPLY)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_project_deadlines(p_project_id UUID DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_entry RECORD;
  v_session public.meeting_sessions;
  v_proj RECORD;
  v_closed_cnt INTEGER := 0;
  v_sah_bersyarat_cnt INTEGER := 0;
  v_unlocked_cnt INTEGER := 0;
  v_finalized_cnt INTEGER := 0;
BEGIN
  -- Allow caller only to sweep projects they belong to when called with client JWT
  IF auth.uid() IS NOT NULL AND p_project_id IS NOT NULL AND NOT public.is_project_member(p_project_id) THEN
    RAISE EXCEPTION 'Access denied';
  END IF;

  -- 1. Logbook Pending > 72 hours -> Sah Bersyarat + award metrics
  FOR v_entry IN
    SELECT * FROM public.logbook_entries
    WHERE status = 'pending'
      AND submitted_at IS NOT NULL
      AND submitted_at <= now() - interval '72 hours'
      AND (p_project_id IS NULL OR project_id = p_project_id)
      AND (auth.uid() IS NULL OR public.is_project_member(project_id))
    FOR UPDATE
  LOOP
    UPDATE public.logbook_entries
    SET status = 'sah_bersyarat', resolved_at = now()
    WHERE id = v_entry.id;

    SELECT * INTO v_session FROM public.meeting_sessions WHERE id = v_entry.session_id;
    PERFORM public.record_verified_meeting_metrics(v_entry.id, v_entry.project_id, v_entry.session_id, COALESCE(v_session.duration_minutes, 60));
    v_sah_bersyarat_cnt := v_sah_bersyarat_cnt + 1;
  END LOOP;

  -- 2. Projects past tenggat -> auto-close to angket_berjalan
  FOR v_proj IN
    SELECT id FROM public.projects
    WHERE status = 'aktif'
      AND tenggat <= now()
      AND (p_project_id IS NULL OR id = p_project_id)
      AND (auth.uid() IS NULL OR public.is_project_member(id))
    FOR UPDATE
  LOOP
    UPDATE public.projects
    SET status = 'angket_berjalan', closed_at = now(), updated_at = now()
    WHERE id = v_proj.id;
    v_closed_cnt := v_closed_cnt + 1;
  END LOOP;

  -- 3. Angket > 48 hours -> Auto-Unlock and run cross-validation
  FOR v_proj IN
    SELECT id FROM public.projects
    WHERE status = 'angket_berjalan'
      AND closed_at IS NOT NULL
      AND closed_at <= now() - interval '48 hours'
      AND (p_project_id IS NULL OR id = p_project_id)
      AND (auth.uid() IS NULL OR public.is_project_member(id))
    FOR UPDATE
  LOOP
    PERFORM public.finalize_survey_and_flags(v_proj.id, TRUE);
    v_unlocked_cnt := v_unlocked_cnt + 1;
  END LOOP;

  -- 4. Tinjauan Hak Jawab > 12 hours -> finish project
  FOR v_proj IN
    SELECT id FROM public.projects
    WHERE status = 'tinjauan_hak_jawab'
      AND flag_review_deadline IS NOT NULL
      AND flag_review_deadline <= now()
      AND (p_project_id IS NULL OR id = p_project_id)
      AND (auth.uid() IS NULL OR public.is_project_member(id))
    FOR UPDATE
  LOOP
    UPDATE public.projects
    SET status = 'selesai', updated_at = now()
    WHERE id = v_proj.id;
    v_finalized_cnt := v_finalized_cnt + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'sah_bersyarat', v_sah_bersyarat_cnt,
    'auto_closed', v_closed_cnt,
    'auto_unlocked_surveys', v_unlocked_cnt,
    'finalized_reviews', v_finalized_cnt
  );
END;
$$;
