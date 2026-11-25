import { callGeminiJson } from '../_shared/gemini.ts';
import { corsHeaders, jsonResponse, requireAuthUser } from '../_shared/supabase_admin.ts';

interface TaskBreakdownOutput {
  tasks: Array<{ title: string; description: string; due_in_days: number }>;
}

interface NotulenOutput {
  summary_md: string;
  todos: Array<{ task: string; owner_name: string | null; status: string }>;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const { user, admin } = await requireAuthUser(req);
    const { action, project_id } = (await req.json()) as {
      action?: 'task_breakdown' | 'auto_notulen' | 'refresh_badges';
      project_id?: string;
    };

    if (!action || !project_id) {
      return jsonResponse({ error: 'action and project_id are required' }, 400);
    }

    const { data: membership } = await admin
      .from('memberships')
      .select('role, is_active')
      .eq('project_id', project_id)
      .eq('user_id', user.id)
      .maybeSingle();

    if (!membership?.is_active) {
      return jsonResponse({ error: 'Active project membership required' }, 403);
    }

    if (action === 'task_breakdown') {
      const { data: project } = await admin
        .from('projects')
        .select('mata_kuliah, judul_tugas, deskripsi_tugas, tenggat')
        .eq('id', project_id)
        .single();

      if (!project) return jsonResponse({ error: 'Project not found' }, 404);

      const schema = {
        type: 'object',
        properties: {
          tasks: {
            type: 'array',
            items: {
              type: 'object',
              properties: {
                title: { type: 'string' },
                description: { type: 'string' },
                due_in_days: { type: 'integer', minimum: 1, maximum: 30 },
              },
              required: ['title', 'description', 'due_in_days'],
            },
          },
        },
        required: ['tasks'],
      };

      const prompt = [
        'Pecah tugas kuliah kelompok berikut menjadi 5 sub-tugas terukur yang adil untuk diklaim mahasiswa.',
        `Mata Kuliah: ${project.mata_kuliah}`,
        `Judul Tugas: ${project.judul_tugas}`,
        `Instruksi Dosen: ${project.deskripsi_tugas ?? 'Susun rancangan materi, kajian pustaka, produk/slide, dan finalisasi.'}`,
      ].join('\n');

      const aiRes = await callGeminiJson<TaskBreakdownOutput>(prompt, schema);
      const tasks = aiRes?.tasks ?? [
        { title: 'Kajian Pustaka & Referensi Jurnal', description: 'Mencari minimal 3 jurnal/sumber utama tervalidasi.', due_in_days: 3 },
        { title: 'Penyusunan Kerangka & Konsep', description: 'Merumuskan struktur bab dan pembagian alur materi.', due_in_days: 3 },
        { title: 'Penulisan Draf Konten Utama', description: 'Menyusun bagian inti naskah/laporan tugas.', due_in_days: 5 },
        { title: 'Desain Slide Presentasi / Media', description: 'Membuat PPT/Canva/LKPD yang ringkas dan visual.', due_in_days: 6 },
        { title: 'Penyuntingan Akhir & Cek Konsistensi', description: 'Menyatukan draf, merapikan sitasi, dan memeriksa format.', due_in_days: 7 },
      ];

      const deadlineMs = new Date(project.tenggat).getTime();
      const rows = tasks.slice(0, 7).map((t) => {
        const targetMs = Math.min(deadlineMs, Date.now() + t.due_in_days * 86400_000);
        return {
          project_id,
          title: t.title,
          description: t.description,
          due_at: new Date(targetMs).toISOString(),
          source: 'ai',
        };
      });

      const { data: inserted, error: insErr } = await admin
        .from('task_items')
        .insert(rows)
        .select();

      if (insErr) throw insErr;
      return jsonResponse({ ok: true, tasks: inserted });
    }

    if (action === 'auto_notulen') {
      const { data: msgs } = await admin
        .from('messages')
        .select('content, intent_label, commitment_text, sender_id, users!messages_sender_id_fkey(nama_asli)')
        .eq('project_id', project_id)
        .neq('intent_label', 'basabasi')
        .order('server_created_at', { ascending: false })
        .limit(60);

      const formatted = (msgs ?? [])
        .reverse()
        .map((m: Record<string, unknown>) => {
          const sender = (m.users as { nama_asli?: string } | null)?.nama_asli ?? 'Anggota';
          return `${sender} [${m.intent_label}]: ${m.content}`;
        })
        .join('\n');

      const schema = {
        type: 'object',
        properties: {
          summary_md: { type: 'string' },
          todos: {
            type: 'array',
            items: {
              type: 'object',
              properties: {
                task: { type: 'string' },
                owner_name: { type: ['string', 'null'] },
                status: { type: 'string' },
              },
              required: ['task', 'owner_name', 'status'],
            },
          },
        },
        required: ['summary_md', 'todos'],
      };

      const prompt = [
        'Buat ringkasan Auto-Notulen rapat obrolan mahasiswa (format Markdown singkat) dan daftar To-Do berdasarkan diskusi bermakna berikut.',
        formatted || '(Belum ada diskusi bermakna.)',
      ].join('\n');

      const aiRes = await callGeminiJson<NotulenOutput>(prompt, schema);
      const summaryMd =
        aiRes?.summary_md ??
        `### Ringkasan Diskusi Terbaru\n- Total pesan bermakna dirangkum: ${(msgs ?? []).length} pesan.\n- Lanjutkan pembagian tugas pada daftar Sub-Tugas Co-Pilot.`;
      const todos = aiRes?.todos ?? [];

      const { data: notulen, error: notErr } = await admin
        .from('notulen_snapshots')
        .insert({
          project_id,
          summary_md: summaryMd,
          todos,
          generated_by: user.id,
        })
        .select()
        .single();

      if (notErr) throw notErr;
      return jsonResponse({ ok: true, notulen });
    }

    // refresh_badges
    const { data: analytics } = await admin.rpc('calculate_project_analytics', {
      p_project_id: project_id,
    });

    const rows = (analytics ?? []) as Array<{
      user_id: string;
      is_active: boolean;
      konseptualisasi_raw: number;
      respons_raw: number;
      riset_berkas_raw: number;
      luring_raw: number;
      contribution_pct: number;
    }>;

    const activeRows = rows.filter((r) => r.is_active);
    const awards: Array<{ project_id: string; user_id: string; badge_code: string; reason: string }> = [];

    const topBy = (field: keyof typeof activeRows[0]) =>
      [...activeRows].sort((a, b) => Number(b[field]) - Number(a[field]))[0];

    const arch = topBy('konseptualisasi_raw');
    if (arch && Number(arch.konseptualisasi_raw) > 0) {
      awards.push({
        project_id,
        user_id: arch.user_id,
        badge_code: 'the_architect',
        reason: 'Kontributor utama gagasan konsep & struktur materi.',
      });
    }

    const hunter = topBy('riset_berkas_raw');
    if (hunter && Number(hunter.riset_berkas_raw) > 0) {
      awards.push({
        project_id,
        user_id: hunter.user_id,
        badge_code: 'literature_hunter',
        reason: 'Aktif menyediakan referensi jurnal & dokumen substantif.',
      });
    }

    const { data: designTop } = await admin
      .from('messages')
      .select('sender_id')
      .eq('project_id', project_id)
      .eq('intent_label', 'desain');

    if (designTop && designTop.length > 0) {
      const counts = new Map<string, number>();
      for (const d of designTop) counts.set(d.sender_id, (counts.get(d.sender_id) ?? 0) + 1);
      const topDesigner = [...counts.entries()].sort((a, b) => b[1] - a[1])[0];
      if (topDesigner) {
        awards.push({
          project_id,
          user_id: topDesigner[0],
          badge_code: 'visual_crafter',
          reason: 'Penggerak utama penyusunan slide presentasi & media visual.',
        });
      }
    }

    const anchor = topBy('respons_raw');
    if (anchor && Number(anchor.respons_raw) > 0) {
      awards.push({
        project_id,
        user_id: anchor.user_id,
        badge_code: 'team_anchor',
        reason: 'Menjaga ritme koordinasi, balasan cepat, dan sinkronisasi tim.',
      });
    }

    if (awards.length > 0) {
      await admin
        .from('badge_awards')
        .upsert(awards, { onConflict: 'project_id,user_id,badge_code' });
    }

    return jsonResponse({ ok: true, awards });
  } catch (err) {
    if (err instanceof Response) return err;
    console.error('copilot-assistant error:', err);
    return jsonResponse({ error: 'Internal server error' }, 500);
  }
});
