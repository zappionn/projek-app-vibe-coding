-- ============================================================================
-- TeamFair v2.0 - 005_badges_in_finalization.sql
-- Deterministic AI Role Micro-Badges refresh RPC + auto-award on finalization
-- ============================================================================

CREATE OR REPLACE FUNCTION public.refresh_project_badges(p_project_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_arch UUID;
  v_hunter UUID;
  v_crafter UUID;
  v_anchor UUID;
BEGIN
  SELECT user_id INTO v_arch
  FROM public.calculate_project_analytics(p_project_id)
  WHERE is_active = TRUE AND konseptualisasi_raw > 0
  ORDER BY konseptualisasi_raw DESC
  LIMIT 1;

  IF v_arch IS NOT NULL THEN
    INSERT INTO public.badge_awards (project_id, user_id, badge_code, reason)
    VALUES (p_project_id, v_arch, 'the_architect', 'Kontributor utama gagasan konsep & struktur materi.')
    ON CONFLICT (project_id, user_id, badge_code) DO NOTHING;
  END IF;

  SELECT user_id INTO v_hunter
  FROM public.calculate_project_analytics(p_project_id)
  WHERE is_active = TRUE AND riset_berkas_raw > 0
  ORDER BY riset_berkas_raw DESC
  LIMIT 1;

  IF v_hunter IS NOT NULL THEN
    INSERT INTO public.badge_awards (project_id, user_id, badge_code, reason)
    VALUES (p_project_id, v_hunter, 'literature_hunter', 'Aktif menyediakan referensi jurnal & dokumen substantif.')
    ON CONFLICT (project_id, user_id, badge_code) DO NOTHING;
  END IF;

  SELECT m.sender_id INTO v_crafter
  FROM public.messages m
  JOIN public.memberships mb ON mb.project_id = m.project_id AND mb.user_id = m.sender_id AND mb.is_active = TRUE
  WHERE m.project_id = p_project_id AND m.intent_label = 'desain'
  GROUP BY m.sender_id
  ORDER BY COUNT(*) DESC
  LIMIT 1;

  IF v_crafter IS NOT NULL THEN
    INSERT INTO public.badge_awards (project_id, user_id, badge_code, reason)
    VALUES (p_project_id, v_crafter, 'visual_crafter', 'Penggerak utama penyusunan slide presentasi & media visual.')
    ON CONFLICT (project_id, user_id, badge_code) DO NOTHING;
  END IF;

  SELECT user_id INTO v_anchor
  FROM public.calculate_project_analytics(p_project_id)
  WHERE is_active = TRUE AND respons_raw > 0
  ORDER BY respons_raw DESC
  LIMIT 1;

  IF v_anchor IS NOT NULL THEN
    INSERT INTO public.badge_awards (project_id, user_id, badge_code, reason)
    VALUES (p_project_id, v_anchor, 'team_anchor', 'Menjaga ritme koordinasi, balasan cepat, dan sinkronisasi tim.')
    ON CONFLICT (project_id, user_id, badge_code) DO NOTHING;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.trg_award_badges_on_eval()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.status IN ('tinjauan_hak_jawab', 'selesai') AND OLD.status = 'angket_berjalan' THEN
    PERFORM public.refresh_project_badges(NEW.id);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_projects_award_badges ON public.projects;
CREATE TRIGGER trg_projects_award_badges
  AFTER UPDATE OF status ON public.projects
  FOR EACH ROW EXECUTE FUNCTION public.trg_award_badges_on_eval();

-- Lock internal SECURITY DEFINER helpers from direct PostgREST client calls
REVOKE ALL ON FUNCTION public.generate_invite_code() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.evaluate_logbook_consensus(UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.record_verified_meeting_metrics(UUID, UUID, UUID, INTEGER) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.finalize_survey_and_flags(UUID, BOOLEAN) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.refresh_project_badges(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.refresh_project_badges(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.finalize_survey_and_flags(UUID, BOOLEAN) TO service_role;
