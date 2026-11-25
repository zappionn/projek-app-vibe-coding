-- ============================================================================
-- TeamFair v2.0 - 004_storage_buckets.sql
-- Private buckets (Free Tier 1 GB optimized) & path-scoped RLS policies
-- Path convention inside buckets: "<project_id>/<filename>"
-- ============================================================================

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES
  (
    'project-attachments',
    'project-attachments',
    FALSE,
    10485760, -- 10 MB max
    ARRAY[
      'application/pdf',
      'application/msword',
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'application/vnd.ms-powerpoint',
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'image/png',
      'image/jpeg'
    ]
  ),
  (
    'attendance-photos',
    'attendance-photos',
    FALSE,
    524288, -- 512 KB hard cap (client compresses <= 300 KB)
    ARRAY['image/jpeg', 'image/webp']
  ),
  (
    'report-snapshots',
    'report-snapshots',
    FALSE,
    10485760, -- 10 MB max PDF
    ARRAY['application/pdf']
  )
ON CONFLICT (id) DO UPDATE SET
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

-- Helper: extract project UUID from first folder segment ("<project_id>/...")
CREATE OR REPLACE FUNCTION public.storage_project_id(object_name TEXT)
RETURNS UUID
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_first TEXT;
BEGIN
  v_first := split_part(object_name, '/', 1);
  RETURN v_first::UUID;
EXCEPTION WHEN OTHERS THEN
  RETURN NULL;
END;
$$;

-- project-attachments policies
CREATE POLICY attachments_storage_select ON storage.objects
  FOR SELECT USING (
    bucket_id = 'project-attachments'
    AND public.is_project_member(public.storage_project_id(name))
  );

CREATE POLICY attachments_storage_insert ON storage.objects
  FOR INSERT WITH CHECK (
    bucket_id = 'project-attachments'
    AND public.is_active_project_member(public.storage_project_id(name))
    AND public.is_project_open(public.storage_project_id(name))
  );

-- attendance-photos policies (only active leader can upload; no overwrite/delete)
CREATE POLICY attendance_storage_select ON storage.objects
  FOR SELECT USING (
    bucket_id = 'attendance-photos'
    AND public.is_project_member(public.storage_project_id(name))
  );

CREATE POLICY attendance_storage_insert ON storage.objects
  FOR INSERT WITH CHECK (
    bucket_id = 'attendance-photos'
    AND public.is_project_leader(public.storage_project_id(name))
    AND public.is_project_open(public.storage_project_id(name))
  );

-- report-snapshots policies (write-once when project is 'selesai')
CREATE POLICY reports_storage_select ON storage.objects
  FOR SELECT USING (
    bucket_id = 'report-snapshots'
    AND public.is_project_member(public.storage_project_id(name))
  );

CREATE POLICY reports_storage_insert ON storage.objects
  FOR INSERT WITH CHECK (
    bucket_id = 'report-snapshots'
    AND public.is_project_member(public.storage_project_id(name))
    AND EXISTS (
      SELECT 1 FROM public.projects p
      WHERE p.id = public.storage_project_id(name)
        AND p.status = 'selesai'
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.report_snapshots rs
      WHERE rs.project_id = public.storage_project_id(name)
    )
  );
