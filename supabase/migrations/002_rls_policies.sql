-- ============================================================================
-- TeamFair v2.0 - 002_rls_policies.sql
-- Row Level Security policies + SECURITY DEFINER helpers (no RLS recursion)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. HELPER FUNCTIONS (BYPASS RLS SAFELY)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_project_member(p_project_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.memberships
    WHERE project_id = p_project_id
      AND user_id = auth.uid()
  );
$$;

CREATE OR REPLACE FUNCTION public.is_active_project_member(p_project_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.memberships
    WHERE project_id = p_project_id
      AND user_id = auth.uid()
      AND is_active = TRUE
  );
$$;

CREATE OR REPLACE FUNCTION public.is_project_leader(p_project_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.memberships
    WHERE project_id = p_project_id
      AND user_id = auth.uid()
      AND role = 'ketua'
      AND is_active = TRUE
  );
$$;

CREATE OR REPLACE FUNCTION public.is_project_open(p_project_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.projects
    WHERE id = p_project_id
      AND status = 'aktif'
  );
$$;

CREATE OR REPLACE FUNCTION public.shares_project_with(p_other_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.memberships m1
    JOIN public.memberships m2 ON m1.project_id = m2.project_id
    WHERE m1.user_id = auth.uid()
      AND m2.user_id = p_other_user_id
  );
$$;

-- ----------------------------------------------------------------------------
-- 2. ENABLE RLS ON ALL TABLES
-- ----------------------------------------------------------------------------
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.device_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.projects ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.leader_transfer_votes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.message_revisions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.attachments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.task_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notulen_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.meeting_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.meeting_photos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.attendance_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.logbook_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.logbook_contributions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.logbook_votes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.activity_metrics ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.peer_assessments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.final_evaluations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.badge_awards ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.report_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

-- ----------------------------------------------------------------------------
-- 3. USERS & DEVICE TOKENS
-- ----------------------------------------------------------------------------
CREATE POLICY users_select_self_or_teammate ON public.users
  FOR SELECT USING (id = auth.uid() OR public.shares_project_with(id));

CREATE POLICY users_update_self ON public.users
  FOR UPDATE USING (id = auth.uid())
  WITH CHECK (id = auth.uid());

CREATE POLICY device_tokens_manage_own ON public.device_tokens
  FOR ALL USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- ----------------------------------------------------------------------------
-- 4. PROJECTS, MEMBERSHIPS & LEADER TRANSFER
-- ----------------------------------------------------------------------------
CREATE POLICY projects_select_member ON public.projects
  FOR SELECT USING (public.is_project_member(id));

CREATE POLICY memberships_select_member ON public.memberships
  FOR SELECT USING (public.is_project_member(project_id));

CREATE POLICY leader_votes_select_member ON public.leader_transfer_votes
  FOR SELECT USING (public.is_project_member(project_id));

-- ----------------------------------------------------------------------------
-- 5. MESSAGES & REVISIONS (APPEND-ONLY)
-- ----------------------------------------------------------------------------
CREATE POLICY messages_select_member ON public.messages
  FOR SELECT USING (public.is_project_member(project_id));

CREATE POLICY messages_insert_active_member ON public.messages
  FOR INSERT WITH CHECK (
    sender_id = auth.uid()
    AND public.is_active_project_member(project_id)
    AND public.is_project_open(project_id)
  );

CREATE POLICY messages_update_own_recent ON public.messages
  FOR UPDATE USING (
    sender_id = auth.uid()
    AND public.is_active_project_member(project_id)
    AND public.is_project_open(project_id)
  )
  WITH CHECK (
    sender_id = auth.uid()
    AND public.is_active_project_member(project_id)
    AND public.is_project_open(project_id)
  );

-- Explicit deny DELETE (append-only)
CREATE POLICY messages_no_delete ON public.messages
  FOR DELETE USING (FALSE);

CREATE POLICY message_revisions_select_member ON public.message_revisions
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.messages m
      WHERE m.id = message_revisions.message_id
        AND public.is_project_member(m.project_id)
    )
  );

-- ----------------------------------------------------------------------------
-- 6. ATTACHMENTS, TASK ITEMS & NOTULEN
-- ----------------------------------------------------------------------------
CREATE POLICY attachments_select_member ON public.attachments
  FOR SELECT USING (public.is_project_member(project_id));

CREATE POLICY attachments_insert_active_member ON public.attachments
  FOR INSERT WITH CHECK (
    uploader_id = auth.uid()
    AND public.is_active_project_member(project_id)
    AND public.is_project_open(project_id)
  );

CREATE POLICY attachments_no_delete ON public.attachments
  FOR DELETE USING (FALSE);

CREATE POLICY task_items_select_member ON public.task_items
  FOR SELECT USING (public.is_project_member(project_id));

CREATE POLICY task_items_insert_active_member ON public.task_items
  FOR INSERT WITH CHECK (
    public.is_active_project_member(project_id)
    AND public.is_project_open(project_id)
  );

CREATE POLICY task_items_update_active_member ON public.task_items
  FOR UPDATE USING (
    public.is_active_project_member(project_id)
    AND public.is_project_open(project_id)
  )
  WITH CHECK (
    public.is_active_project_member(project_id)
    AND public.is_project_open(project_id)
  );

CREATE POLICY notulen_select_member ON public.notulen_snapshots
  FOR SELECT USING (public.is_project_member(project_id));

-- ----------------------------------------------------------------------------
-- 7. OFFLINE MEETINGS, PHOTOS, ATTENDANCE, LOGBOOK
-- ----------------------------------------------------------------------------
CREATE POLICY meeting_sessions_select_member ON public.meeting_sessions
  FOR SELECT USING (public.is_project_member(project_id));

CREATE POLICY meeting_sessions_insert_leader ON public.meeting_sessions
  FOR INSERT WITH CHECK (
    started_by = auth.uid()
    AND public.is_project_leader(project_id)
    AND public.is_project_open(project_id)
  );

CREATE POLICY meeting_sessions_update_leader ON public.meeting_sessions
  FOR UPDATE USING (
    public.is_project_leader(project_id)
    AND public.is_project_open(project_id)
  )
  WITH CHECK (
    public.is_project_leader(project_id)
    AND public.is_project_open(project_id)
  );

CREATE POLICY meeting_photos_select_member ON public.meeting_photos
  FOR SELECT USING (public.is_project_member(project_id));

CREATE POLICY meeting_photos_insert_leader ON public.meeting_photos
  FOR INSERT WITH CHECK (
    uploaded_by = auth.uid()
    AND public.is_project_leader(project_id)
    AND public.is_project_open(project_id)
  );

CREATE POLICY meeting_photos_no_delete ON public.meeting_photos
  FOR DELETE USING (FALSE);

CREATE POLICY attendance_select_member ON public.attendance_records
  FOR SELECT USING (public.is_project_member(project_id));

CREATE POLICY attendance_insert_leader ON public.attendance_records
  FOR INSERT WITH CHECK (
    public.is_project_leader(project_id)
    AND public.is_project_open(project_id)
  );

CREATE POLICY logbook_entries_select_member ON public.logbook_entries
  FOR SELECT USING (public.is_project_member(project_id));

CREATE POLICY logbook_contributions_select_member ON public.logbook_contributions
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.logbook_entries le
      WHERE le.id = logbook_contributions.entry_id
        AND public.is_project_member(le.project_id)
    )
  );

CREATE POLICY logbook_contributions_upsert_leader ON public.logbook_contributions
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM public.logbook_entries le
      WHERE le.id = logbook_contributions.entry_id
        AND le.status = 'draf'
        AND public.is_project_leader(le.project_id)
        AND public.is_project_open(le.project_id)
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.logbook_entries le
      WHERE le.id = logbook_contributions.entry_id
        AND le.status = 'draf'
        AND public.is_project_leader(le.project_id)
        AND public.is_project_open(le.project_id)
    )
  );

CREATE POLICY logbook_votes_select_member ON public.logbook_votes
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.logbook_entries le
      WHERE le.id = logbook_votes.entry_id
        AND public.is_project_member(le.project_id)
    )
  );

CREATE POLICY logbook_votes_no_delete ON public.logbook_votes
  FOR DELETE USING (FALSE);

-- ----------------------------------------------------------------------------
-- 8. METRICS, PEER ASSESSMENTS (STRICT), EVALUATIONS, BADGES, REPORTS, NOTIFS
-- ----------------------------------------------------------------------------
CREATE POLICY activity_metrics_select_member ON public.activity_metrics
  FOR SELECT USING (public.is_project_member(project_id));

-- STRICT ANONYMITY: Only rater can read their own submitted rows; writes go via RPC.
CREATE POLICY peer_assessments_select_own ON public.peer_assessments
  FOR SELECT USING (rater_id = auth.uid());

CREATE POLICY final_evaluations_select_member ON public.final_evaluations
  FOR SELECT USING (public.is_project_member(project_id));

CREATE POLICY badge_awards_select_member ON public.badge_awards
  FOR SELECT USING (public.is_project_member(project_id));

CREATE POLICY report_snapshots_select_member ON public.report_snapshots
  FOR SELECT USING (public.is_project_member(project_id));

CREATE POLICY report_snapshots_no_delete ON public.report_snapshots
  FOR DELETE USING (FALSE);

CREATE POLICY notifications_select_own ON public.notifications
  FOR SELECT USING (user_id = auth.uid());

CREATE POLICY notifications_update_own ON public.notifications
  FOR UPDATE USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());
