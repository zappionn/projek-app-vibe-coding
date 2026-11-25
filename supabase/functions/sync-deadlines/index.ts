import { dispatchNotifications } from '../_shared/fcm.ts';
import { corsHeaders, getAdminClient, jsonResponse, requireAuthUser } from '../_shared/supabase_admin.ts';

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const cronSecret = Deno.env.get('CRON_SECRET');
    const reqSecret = req.headers.get('x-cron-secret');
    const isCron = Boolean(cronSecret && reqSecret === cronSecret);

    let projectId: string | null = null;
    const admin = getAdminClient();

    if (req.method === 'POST') {
      const body = await req.json().catch(() => ({}));
      projectId = typeof body?.project_id === 'string' ? body.project_id : null;
    }

    if (!isCron) {
      const { user } = await requireAuthUser(req);
      if (!projectId) {
        return jsonResponse({ error: 'project_id required for client invocation' }, 400);
      }
      const { data: member } = await admin
        .from('memberships')
        .select('id')
        .eq('project_id', projectId)
        .eq('user_id', user.id)
        .maybeSingle();
      if (!member) {
        return jsonResponse({ error: 'Forbidden' }, 403);
      }
    }

    const { data: sweepSummary, error: rpcErr } = await admin.rpc('sync_project_deadlines', {
      p_project_id: projectId,
    });

    if (rpcErr) throw rpcErr;

    // When invoked by cron, also send overdue reminders for pending logbooks (24h/48h) & surveys (12h/24h/36h)
    let remindersSent = 0;
    if (isCron) {
      const { data: pendingEntries } = await admin
        .from('logbook_entries')
        .select('id, project_id, submitted_at')
        .eq('status', 'pending')
        .lt('submitted_at', new Date(Date.now() - 24 * 3600_000).toISOString());

      for (const entry of pendingEntries ?? []) {
        const { data: members } = await admin
          .from('memberships')
          .select('user_id')
          .eq('project_id', entry.project_id)
          .eq('is_active', true);
        const { data: votes } = await admin
          .from('logbook_votes')
          .select('user_id')
          .eq('entry_id', entry.id);

        const votedSet = new Set((votes ?? []).map((v) => v.user_id));
        const unvoted = (members ?? []).map((m) => m.user_id).filter((id) => !votedSet.has(id));
        if (unvoted.length > 0) {
          await dispatchNotifications(admin, {
            projectId: entry.project_id,
            userIds: unvoted,
            type: 'logbook_reminder',
            title: 'Validasi Logbook Menunggu',
            body: 'Mohon tinjau dan setujui laporan pertemuan luring kelompok Anda.',
            payload: { entry_id: entry.id },
          });
          remindersSent += unvoted.length;
        }
      }
    }

    return jsonResponse({ ok: true, summary: sweepSummary, reminders_sent: remindersSent });
  } catch (err) {
    if (err instanceof Response) return err;
    console.error('sync-deadlines error:', err);
    return jsonResponse({ error: 'Internal server error' }, 500);
  }
});
