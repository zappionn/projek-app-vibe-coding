import { dispatchNotifications } from '../_shared/fcm.ts';
import { corsHeaders, jsonResponse, requireAuthUser } from '../_shared/supabase_admin.ts';

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const { user, admin } = await requireAuthUser(req);
    const {
      project_id,
      target_user_ids,
      type,
      title,
      body,
      payload,
    } = (await req.json()) as {
      project_id?: string;
      target_user_ids?: string[];
      type?: string;
      title?: string;
      body?: string;
      payload?: Record<string, string>;
    };

    if (!project_id || !type || !title || !body) {
      return jsonResponse({ error: 'project_id, type, title, and body are required' }, 400);
    }

    const { data: caller } = await admin
      .from('memberships')
      .select('is_active')
      .eq('project_id', project_id)
      .eq('user_id', user.id)
      .maybeSingle();

    if (!caller?.is_active) {
      return jsonResponse({ error: 'Forbidden' }, 403);
    }

    let recipients = target_user_ids;
    if (!recipients || recipients.length === 0) {
      const { data: members } = await admin
        .from('memberships')
        .select('user_id')
        .eq('project_id', project_id)
        .eq('is_active', true)
        .neq('user_id', user.id);
      recipients = (members ?? []).map((m) => m.user_id);
    }

    const result = await dispatchNotifications(admin, {
      projectId: project_id,
      userIds: recipients,
      type,
      title,
      body,
      payload,
    });

    return jsonResponse({ ok: true, ...result });
  } catch (err) {
    if (err instanceof Response) return err;
    console.error('send-push-fcm error:', err);
    return jsonResponse({ error: 'Internal server error' }, 500);
  }
});
