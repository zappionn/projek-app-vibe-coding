import { callGeminiJson } from '../_shared/gemini.ts';
import { corsHeaders, jsonResponse, requireAuthUser } from '../_shared/supabase_admin.ts';

interface DiffEval {
  diff_score: number;
  summary: string;
  matched_concept_message_ids: string[];
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const { user, admin } = await requireAuthUser(req);
    const { attachment_id } = (await req.json()) as { attachment_id?: string };
    if (!attachment_id) {
      return jsonResponse({ error: 'attachment_id is required' }, 400);
    }

    const { data: att, error: attErr } = await admin
      .from('attachments')
      .select('*')
      .eq('id', attachment_id)
      .single();

    if (attErr || !att) {
      return jsonResponse({ error: 'Attachment not found' }, 404);
    }

    const { data: member } = await admin
      .from('memberships')
      .select('id')
      .eq('project_id', att.project_id)
      .eq('user_id', user.id)
      .maybeSingle();

    if (!member) {
      return jsonResponse({ error: 'Forbidden' }, 403);
    }

    // 1. Check SHA-256 duplicate inside the same project
    if (att.sha256_hash) {
      const { data: dup } = await admin
        .from('attachments')
        .select('id')
        .eq('project_id', att.project_id)
        .eq('sha256_hash', att.sha256_hash)
        .neq('id', att.id)
        .limit(1)
        .maybeSingle();

      if (dup) {
        await admin
          .from('attachments')
          .update({ is_duplicate: true, diff_score: 0 })
          .eq('id', att.id);
        await admin.from('activity_metrics').delete().eq('source_ref_id', att.id);
        return jsonResponse({ ok: true, is_duplicate: true, diff_score: 0 });
      }
    }

    // 2. Gather parent revision & recent concept messages for Idea-to-Output Tracking
    let parentContext = 'Dokumen baru (bukan revisi).';
    if (att.parent_attachment_id) {
      const { data: parent } = await admin
        .from('attachments')
        .select('file_name, extracted_summary, changelog')
        .eq('id', att.parent_attachment_id)
        .maybeSingle();
      if (parent) {
        parentContext = `Versi induk: ${parent.file_name} | Ringkasan lama: ${parent.extracted_summary ?? '-'}`;
      }
    }

    const { data: conceptMsgs } = await admin
      .from('messages')
      .select('id, sender_id, content')
      .eq('project_id', att.project_id)
      .eq('intent_label', 'konsep')
      .order('server_created_at', { ascending: false })
      .limit(15);

    const schema = {
      type: 'object',
      properties: {
        diff_score: { type: 'number', minimum: 0.2, maximum: 2.0 },
        summary: { type: 'string' },
        matched_concept_message_ids: { type: 'array', items: { type: 'string' } },
      },
      required: ['diff_score', 'summary', 'matched_concept_message_ids'],
    };

    const conceptLines = (conceptMsgs ?? [])
      .map((m) => `[${m.id}] ${m.content.slice(0, 160)}`)
      .join('\n');

    const prompt = [
      'Evaluasi kontribusi berkas/revisi tugas kelompok mahasiswa.',
      `Nama berkas: ${att.file_name} (${att.kind})`,
      `Changelog pengunggah: ${att.changelog ?? 'Tidak ada'}`,
      `Ringkasan teks berkas: ${(att.extracted_summary ?? '').slice(0, 1200)}`,
      parentContext,
      'Daftar gagasan konsep di obrolan (Idea-to-Output):',
      conceptLines || '(belum ada)',
      'Berikan diff_score (0.2 = perubahan kosmetik kecil, 1.0 = kontribusi standar, 2.0 = revisi/draf substantif besar), ringkasan singkat 1 kalimat, dan daftar id pesan konsep yang idenya tampak diadopsi ke dokumen ini.',
    ].join('\n');

    const aiEval = await callGeminiJson<DiffEval>(prompt, schema);
    const diffScore = aiEval?.diff_score ?? (att.parent_attachment_id ? 1.1 : 1.3);
    const summary = aiEval?.summary ?? att.changelog ?? att.file_name;

    await admin
      .from('attachments')
      .update({
        diff_score,
        extracted_summary: summary,
        is_duplicate: false,
      })
      .eq('id', att.id);

    await admin.from('activity_metrics').delete().eq('source_ref_id', att.id);
    await admin.from('activity_metrics').insert({
      project_id: att.project_id,
      user_id: att.uploader_id,
      component: 'riset_berkas',
      raw_score: Number((10 * diffScore).toFixed(2)),
      source_ref_id: att.id,
    });

    // Award Idea-to-Output bonus to proposers whose concepts were adopted
    const matchedIds = new Set(aiEval?.matched_concept_message_ids ?? []);
    if (matchedIds.size > 0 && conceptMsgs) {
      const bonusRows = conceptMsgs
        .filter((m) => matchedIds.has(m.id))
        .map((m) => ({
          project_id: att.project_id,
          user_id: m.sender_id,
          component: 'konseptualisasi',
          raw_score: 3.0,
          source_ref_id: att.id,
        }));
      if (bonusRows.length > 0) {
        await admin.from('activity_metrics').insert(bonusRows);
      }
    }

    return jsonResponse({
      ok: true,
      is_duplicate: false,
      diff_score: diffScore,
      summary,
      adopted_concepts: [...matchedIds],
    });
  } catch (err) {
    if (err instanceof Response) return err;
    console.error('evaluate-file-diff error:', err);
    return jsonResponse({ error: 'Internal server error' }, 500);
  }
});
