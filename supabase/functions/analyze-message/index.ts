import { callGeminiJson } from '../_shared/gemini.ts';
import { corsHeaders, jsonResponse, requireAuthUser } from '../_shared/supabase_admin.ts';

interface IntentAnalysis {
  intent_label: 'konsep' | 'riset' | 'desain' | 'koordinasi' | 'basabasi';
  quality_score: number;
  has_commitment: boolean;
  commitment_text: string | null;
  commitment_due_hours: number | null;
}

const FILLER_PHRASES = new Set([
  'oke', 'ok', 'oke siap', 'ok siap', 'siap', 'siap kak', 'siap bang',
  'iya', 'iya nanti', 'iya nanti ya', 'iya siap', 'ikut', 'ikut aja', 'ikut saja',
  'gas', 'sip', 'baik', 'noted', 'otw', 'mantap', 'makasih', 'terima kasih',
  'sama sama', 'wkwk', 'wkwkwk', 'haha', 'hehe', 'amin', 'lanjut',
]);

function normalizeForFilter(text: string): string {
  return text
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s]/gu, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function heuristicFallback(content: string, hasReply: boolean, hasAttachment: boolean): IntentAnalysis {
  const norm = normalizeForFilter(content);
  const words = norm ? norm.split(' ') : [];

  if (!hasAttachment && (FILLER_PHRASES.has(norm) || words.length < 4)) {
    return {
      intent_label: 'basabasi',
      quality_score: 0,
      has_commitment: false,
      commitment_text: null,
      commitment_due_hours: null,
    };
  }

  if (/(jurnal|referensi|literatur|pustaka|doi|artikel|buku|sitasi)/.test(norm)) {
    return { intent_label: 'riset', quality_score: 7, has_commitment: false, commitment_text: null, commitment_due_hours: null };
  }
  if (/(slide|ppt|canva|desain|lkpd|infografis|layout|poster|figma)/.test(norm)) {
    return { intent_label: 'desain', quality_score: 7, has_commitment: false, commitment_text: null, commitment_due_hours: null };
  }
  if (/(konsep|kerangka|hipotesis|metode|rumusan|rpp|alur|struktur|bab|analisis)/.test(norm)) {
    return { intent_label: 'konsep', quality_score: 8, has_commitment: false, commitment_text: null, commitment_due_hours: null };
  }

  return {
    intent_label: hasReply ? 'koordinasi' : 'koordinasi',
    quality_score: hasReply ? 5 : 4,
    has_commitment: /(aku kerjakan|saya kerjakan|aku buat|nanti malam|besok aku|aku kumpulkan)/.test(norm),
    commitment_text: /(aku kerjakan|saya kerjakan|aku buat|nanti malam|besok aku|aku kumpulkan)/.test(norm)
      ? content.slice(0, 120)
      : null,
    commitment_due_hours: 24,
  };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const { user, admin } = await requireAuthUser(req);
    const { message_id } = (await req.json()) as { message_id?: string };
    if (!message_id) {
      return jsonResponse({ error: 'message_id is required' }, 400);
    }

    const { data: msg, error: msgErr } = await admin
      .from('messages')
      .select('id, project_id, sender_id, content, has_attachment, reply_to_id, intent_label')
      .eq('id', message_id)
      .single();

    if (msgErr || !msg) {
      return jsonResponse({ error: 'Message not found' }, 404);
    }

    const { data: membership } = await admin
      .from('memberships')
      .select('id')
      .eq('project_id', msg.project_id)
      .eq('user_id', user.id)
      .maybeSingle();

    if (!membership) {
      return jsonResponse({ error: 'Forbidden' }, 403);
    }

    const norm = normalizeForFilter(msg.content);
    const words = norm ? norm.split(' ') : [];

    let result: IntentAnalysis;

    // Fast-path heuristic filter to save Gemini API quota on obvious filler messages
    if (!msg.has_attachment && (FILLER_PHRASES.has(norm) || words.length < 4)) {
      result = {
        intent_label: 'basabasi',
        quality_score: 0,
        has_commitment: false,
        commitment_text: null,
        commitment_due_hours: null,
      };
    } else {
      const schema = {
        type: 'object',
        properties: {
          intent_label: {
            type: 'string',
            enum: ['konsep', 'riset', 'desain', 'koordinasi', 'basabasi'],
          },
          quality_score: { type: 'number', minimum: 0, maximum: 10 },
          has_commitment: { type: 'boolean' },
          commitment_text: { type: ['string', 'null'] },
          commitment_due_hours: { type: ['number', 'null'] },
        },
        required: ['intent_label', 'quality_score', 'has_commitment', 'commitment_text', 'commitment_due_hours'],
      };

      const prompt = [
        'Kamu adalah evaluator kolaborasi akademik mahasiswa Indonesia.',
        'Klasifikasikan pesan obrolan tugas kelompok berikut ke satu kategori intent_label:',
        '- konsep: mengusulkan ide, kerangka, rumusan masalah, metode, alur pembelajaran, atau analisis isi.',
        '- riset: membagikan/membahas jurnal, literatur, data penelitian, atau rujukan ilmiah.',
        '- desain: mengerjakan/membahas slide PPT, Canva, LKPD, diagram, atau tata letak produk.',
        '- koordinasi: penjadwalan konkret, pembagian tugas jelas, atau tindak lanjut teknis.',
        '- basabasi: respons singkat tanpa substansi ("oke siap", "iya nanti ya", "ikut aja", spam). Nilai quality_score WAJIB 0.',
        'Juga deteksi apakah pengirim mengucapkan janji/komitmen mengerjakan bagian tugas (has_commitment, ringkasan commitment_text bahasa Indonesia, dan perkiraan commitment_due_hours).',
        `Pesan (reply=${Boolean(msg.reply_to_id)}, ada_lampiran=${msg.has_attachment}): "${msg.content}"`,
      ].join('\n');

      const aiResult = await callGeminiJson<IntentAnalysis>(prompt, schema);
      result = aiResult ?? heuristicFallback(msg.content, Boolean(msg.reply_to_id), Boolean(msg.has_attachment));
    }

    if (result.intent_label === 'basabasi') {
      result.quality_score = 0;
    }

    const dueAt = result.has_commitment && result.commitment_text
      ? new Date(Date.now() + Math.max(1, result.commitment_due_hours ?? 24) * 3600_000).toISOString()
      : null;

    await admin
      .from('messages')
      .update({
        intent_label: result.intent_label,
        intent_score: result.quality_score,
        commitment_text: result.has_commitment ? result.commitment_text : null,
        commitment_due_at: dueAt,
      })
      .eq('id', msg.id);

    // Replace/insert metric idempotently for this message
    await admin
      .from('activity_metrics')
      .delete()
      .eq('source_ref_id', msg.id)
      .in('component', ['konseptualisasi', 'respons', 'riset_berkas']);

    if (result.intent_label !== 'basabasi' && result.quality_score > 0) {
      const component =
        result.intent_label === 'konsep'
          ? 'konseptualisasi'
          : result.intent_label === 'riset' || result.intent_label === 'desain'
          ? 'riset_berkas'
          : 'respons';

      await admin.from('activity_metrics').insert({
        project_id: msg.project_id,
        user_id: msg.sender_id,
        component,
        raw_score: Number(result.quality_score.toFixed(2)),
        source_ref_id: msg.id,
      });

      if (msg.reply_to_id && component !== 'respons') {
        await admin.from('activity_metrics').insert({
          project_id: msg.project_id,
          user_id: msg.sender_id,
          component: 'respons',
          raw_score: 2.0,
          source_ref_id: msg.id,
        });
      }
    }

    return jsonResponse({ ok: true, message_id: msg.id, analysis: result });
  } catch (err) {
    if (err instanceof Response) return err;
    console.error('analyze-message error:', err);
    return jsonResponse({ error: 'Internal server error' }, 500);
  }
});
