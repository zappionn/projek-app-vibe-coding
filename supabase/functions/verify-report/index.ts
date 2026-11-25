import { getAdminClient } from '../_shared/supabase_admin.ts';

function escapeHtml(raw: string): string {
  return raw
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

function statusBadge(status: string): string {
  if (status === 'anomali') {
    return '<span style="background:#FEE2E2;color:#991B1B;padding:3px 8px;border-radius:99px;font-weight:600;font-size:12px;">ANOMALI</span>';
  }
  if (status === 'perlu_dicermati') {
    return '<span style="background:#FEF3C7;color:#92400E;padding:3px 8px;border-radius:99px;font-weight:600;font-size:12px;">Perlu dicermati</span>';
  }
  return '<span style="background:#DCFCE7;color:#166534;padding:3px 8px;border-radius:99px;font-weight:600;font-size:12px;">Konsisten</span>';
}

Deno.serve(async (req) => {
  try {
    const url = new URL(req.url);
    const code = url.searchParams.get('code')?.trim();
    const projectId = url.searchParams.get('project_id')?.trim();

    if (!code && !projectId) {
      return new Response('Parameter code atau project_id wajib disertakan.', { status: 400 });
    }

    const admin = getAdminClient();
    let snapQuery = admin.from('report_snapshots').select('*');
    snapQuery = code ? snapQuery.eq('report_code', code) : snapQuery.eq('project_id', projectId!);
    const { data: snapshot, error: snapErr } = await snapQuery.maybeSingle();

    if (snapErr || !snapshot) {
      return new Response(
        '<html><body style="font-family:sans-serif;padding:24px;"><h2>Laporan Tidak Ditemukan</h2><p>ID Laporan atau kode verifikasi tidak valid di sistem TeamFair.</p></body></html>',
        { status: 404, headers: { 'Content-Type': 'text/html; charset=utf-8' } },
      );
    }

    const { data: project } = await admin
      .from('projects')
      .select('mata_kuliah, judul_tugas, created_at, closed_at')
      .eq('id', snapshot.project_id)
      .single();

    const { data: evals } = await admin
      .from('final_evaluations')
      .select('user_id, contribution_pct, system_score, self_score, peer_avg_score, flag_status, collusion_warning, right_of_reply, users!final_evaluations_user_id_fkey(nama_asli, npm_nim)')
      .eq('project_id', snapshot.project_id)
      .order('contribution_pct', { ascending: false });

    const rowsHtml = (evals ?? [])
      .map((e: Record<string, unknown>) => {
        const u = e.users as { nama_asli?: string; npm_nim?: string } | null;
        const nama = escapeHtml(u?.nama_asli ?? 'Mahasiswa');
        const npm = escapeHtml(u?.npm_nim ?? '-');
        const reply = typeof e.right_of_reply === 'string' && e.right_of_reply.trim()
          ? `<div style="margin-top:4px;font-size:12px;color:#4B5563;"><strong>Hak Jawab:</strong> ${escapeHtml(e.right_of_reply)}</div>`
          : '';
        return `
          <tr>
            <td style="padding:10px;border-bottom:1px solid #E5E7EB;">
              <div style="font-weight:600;color:#111827;">${nama}</div>
              <div style="font-size:12px;color:#6B7280;">${npm}</div>
              ${reply}
            </td>
            <td style="padding:10px;border-bottom:1px solid #E5E7EB;text-align:right;">${Number(e.contribution_pct).toFixed(1)}%</td>
            <td style="padding:10px;border-bottom:1px solid #E5E7EB;text-align:right;font-weight:600;">${e.system_score}</td>
            <td style="padding:10px;border-bottom:1px solid #E5E7EB;text-align:right;">${e.self_score ?? '-'}</td>
            <td style="padding:10px;border-bottom:1px solid #E5E7EB;text-align:right;">${e.peer_avg_score ?? '-'}</td>
            <td style="padding:10px;border-bottom:1px solid #E5E7EB;">${statusBadge(String(e.flag_status))}</td>
          </tr>
        `;
      })
      .join('');

    const html = `<!DOCTYPE html>
<html lang="id">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Verifikasi Laporan TeamFair - ${escapeHtml(snapshot.report_code)}</title>
</head>
<body style="margin:0;background:#F5F6FA;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;color:#1F2937;">
  <div style="max-width:760px;margin:24px auto;background:#FFFFFF;border-radius:16px;border:1px solid #E3E6EE;overflow:hidden;">
    <div style="background:#14213D;color:#FFFFFF;padding:20px 24px;">
      <div style="font-size:12px;opacity:0.85;letter-spacing:0.5px;">VERIFIKASI RESMI TEAMFAIR</div>
      <h1 style="margin:6px 0 0;font-size:20px;">${escapeHtml(project?.judul_tugas ?? 'Laporan Audit Akademik')}</h1>
      <div style="margin-top:4px;font-size:14px;opacity:0.9;">${escapeHtml(project?.mata_kuliah ?? '')}</div>
    </div>
    <div style="padding:20px 24px;">
      <div style="background:#ECFDF5;border:1px solid #A7F3D0;color:#065F46;padding:12px 14px;border-radius:10px;margin-bottom:16px;font-size:14px;">
        <strong>Dokumen Terverifikasi Asli</strong> &middot; ID: <code>${escapeHtml(snapshot.report_code)}</code><br/>
        Status Angket: ${escapeHtml(snapshot.survey_completion_note)}
      </div>
      <div style="font-size:12px;color:#6B7280;word-break:break-all;margin-bottom:16px;">
        <strong>SHA-256 PDF:</strong> <code>${escapeHtml(snapshot.hash_sha256)}</code><br/>
        <strong>Dibuat pada (UTC):</strong> ${escapeHtml(String(snapshot.created_at))}
      </div>
      <div style="overflow-x:auto;">
        <table style="width:100%;border-collapse:collapse;font-size:14px;">
          <thead>
            <tr style="background:#F9FAFB;text-align:left;color:#374151;">
              <th style="padding:10px;border-bottom:2px solid #E5E7EB;">Anggota</th>
              <th style="padding:10px;border-bottom:2px solid #E5E7EB;text-align:right;">Kontribusi</th>
              <th style="padding:10px;border-bottom:2px solid #E5E7EB;text-align:right;">Skor AI</th>
              <th style="padding:10px;border-bottom:2px solid #E5E7EB;text-align:right;">Skor Diri</th>
              <th style="padding:10px;border-bottom:2px solid #E5E7EB;text-align:right;">Rerata Teman</th>
              <th style="padding:10px;border-bottom:2px solid #E5E7EB;">Status</th>
            </tr>
          </thead>
          <tbody>${rowsHtml}</tbody>
        </table>
      </div>
      <p style="margin-top:16px;font-size:12px;color:#6B7280;">
        Catatan: Bendera status bersifat indikatif berbasis jejak kolaborasi & penilaian sejawat. Keputusan penilaian akhir tetap berada pada dosen pengampu.
      </p>
    </div>
  </div>
</body>
</html>`;

    return new Response(html, {
      status: 200,
      headers: { 'Content-Type': 'text/html; charset=utf-8' },
    });
  } catch (err) {
    console.error('verify-report error:', err);
    return new Response('Terjadi kesalahan saat memverifikasi laporan.', { status: 500 });
  }
});
