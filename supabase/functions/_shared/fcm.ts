import type { SupabaseClient } from 'jsr:@supabase/supabase-js@2';

interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
}

export interface NotificationDispatch {
  projectId: string;
  userIds: string[];
  type: string;
  title: string;
  body: string;
  payload?: Record<string, string>;
}

function base64UrlEncode(input: Uint8Array | string): string {
  const bytes = typeof input === 'string' ? new TextEncoder().encode(input) : input;
  let binary = '';
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

async function importPemPrivateKey(pem: string): Promise<CryptoKey> {
  const cleaned = pem
    .replace('-----BEGIN PRIVATE KEY-----', '')
    .replace('-----END PRIVATE KEY-----', '')
    .replace(/\s+/g, '');
  const binary = atob(cleaned);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return await crypto.subtle.importKey(
    'pkcs8',
    bytes.buffer,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );
}

async function getFcmAccessToken(sa: ServiceAccount): Promise<string | null> {
  try {
    const nowSec = Math.floor(Date.now() / 1000);
    const header = base64UrlEncode(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
    const claim = base64UrlEncode(
      JSON.stringify({
        iss: sa.client_email,
        scope: 'https://www.googleapis.com/auth/firebase.messaging',
        aud: 'https://oauth2.googleapis.com/token',
        iat: nowSec,
        exp: nowSec + 3600,
      }),
    );
    const signingInput = `${header}.${claim}`;
    const key = await importPemPrivateKey(sa.private_key);
    const sigBuffer = await crypto.subtle.sign(
      'RSASSA-PKCS1-v1_5',
      key,
      new TextEncoder().encode(signingInput),
    );
    const jwt = `${signingInput}.${base64UrlEncode(new Uint8Array(sigBuffer))}`;

    const tokenRes = await fetch('https://oauth2.googleapis.com/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
        assertion: jwt,
      }),
    });
    if (!tokenRes.ok) return null;
    const tokenJson = (await tokenRes.json()) as { access_token?: string };
    return tokenJson.access_token ?? null;
  } catch (err) {
    console.error('Failed to mint FCM OAuth token:', err);
    return null;
  }
}

export async function dispatchNotifications(
  admin: SupabaseClient,
  input: NotificationDispatch,
): Promise<{ stored: number; pushed: number }> {
  if (input.userIds.length === 0) return { stored: 0, pushed: 0 };

  const uniqueUsers = [...new Set(input.userIds)];
  const rows = uniqueUsers.map((uid) => ({
    user_id: uid,
    project_id: input.projectId,
    type: input.type,
    title: input.title,
    body: input.body,
    payload: input.payload ?? {},
  }));

  const { error: insertErr } = await admin.from('notifications').insert(rows);
  if (insertErr) {
    console.error('Failed inserting notifications:', insertErr);
  }

  const saRaw = Deno.env.get('FCM_SERVICE_ACCOUNT_JSON');
  if (!saRaw) {
    return { stored: uniqueUsers.length, pushed: 0 };
  }

  let sa: ServiceAccount;
  try {
    sa = JSON.parse(saRaw) as ServiceAccount;
  } catch {
    return { stored: uniqueUsers.length, pushed: 0 };
  }

  const accessToken = await getFcmAccessToken(sa);
  if (!accessToken) {
    return { stored: uniqueUsers.length, pushed: 0 };
  }

  const { data: tokens } = await admin
    .from('device_tokens')
    .select('fcm_token')
    .in('user_id', uniqueUsers);

  if (!tokens || tokens.length === 0) {
    return { stored: uniqueUsers.length, pushed: 0 };
  }

  let pushed = 0;
  const fcmUrl = `https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`;

  await Promise.all(
    tokens.map(async ({ fcm_token }) => {
      try {
        const res = await fetch(fcmUrl, {
          method: 'POST',
          headers: {
            Authorization: `Bearer ${accessToken}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({
            message: {
              token: fcm_token,
              notification: { title: input.title, body: input.body },
              data: {
                project_id: input.projectId,
                type: input.type,
                ...(input.payload ?? {}),
              },
              android: {
                priority: 'high',
                notification: {
                  channel_id: 'teamfair_important',
                },
              },
            },
          }),
        });
        if (res.ok) {
          pushed++;
        } else if (res.status === 404 || res.status === 410) {
          await admin.from('device_tokens').delete().eq('fcm_token', fcm_token);
        }
      } catch (err) {
        console.error('FCM push error:', err);
      }
    }),
  );

  return { stored: uniqueUsers.length, pushed };
}
