/**
 * jarvis-push — v1
 * Envía una notificación al iPhone (APNs) cuando un agente crea una alerta.
 * Se dispara con un Database Webhook de Supabase sobre INSERT en public.alerts,
 * firmado con la cabecera x-webhook-secret.
 * Secretos: APNS_KEY_P8 (contenido del .p8), APNS_KEY_ID, APNS_TEAM_ID,
 * APNS_BUNDLE_ID, PUSH_WEBHOOK_SECRET.
 */
import { admin, json } from "../_shared/auth.ts";

const AGENT_NAME: Record<string, string> = {
  jarvis: "JARVIS", ultron: "ULTRÓN", ares: "ARES", aura: "AURA", ray: "Ray", midas: "MIDAS", donna: "Donna",
};

const b64url = (buf: ArrayBuffer | Uint8Array) =>
  btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

let cached: { token: string; at: number } | null = null;

async function providerToken(): Promise<string> {
  // APNs acepta el mismo token hasta 60 min; se renueva a los 50
  if (cached && Date.now() - cached.at < 50 * 60_000) return cached.token;
  const pem = Deno.env.get("APNS_KEY_P8")!.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const enc = new TextEncoder();
  const header = b64url(enc.encode(JSON.stringify({ alg: "ES256", kid: Deno.env.get("APNS_KEY_ID") })));
  const claims = b64url(enc.encode(JSON.stringify({ iss: Deno.env.get("APNS_TEAM_ID"), iat: Math.floor(Date.now() / 1000) })));
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, enc.encode(`${header}.${claims}`));
  cached = { token: `${header}.${claims}.${b64url(sig)}`, at: Date.now() };
  return cached.token;
}

Deno.serve(async (req) => {
  const secret = Deno.env.get("PUSH_WEBHOOK_SECRET") ?? "";
  if (!secret || req.headers.get("x-webhook-secret") !== secret) return json({ error: "unauthorized" }, 401);

  const evt = await req.json().catch(() => null);
  const alert = evt?.record;
  if (evt?.type !== "INSERT" || !alert?.text) return json({ ok: true, skipped: true });

  const db = admin();
  const { data: devices } = await db.from("devices").select("token, environment");
  if (!devices?.length) return json({ ok: true, sent: 0 });

  const payload = JSON.stringify({
    aps: {
      alert: { title: AGENT_NAME[alert.agent] ?? "JARVIS", body: alert.text },
      sound: alert.level === "critical" ? "default" : undefined,
      "interruption-level": alert.level === "critical" ? "time-sensitive" : "active",
      "thread-id": alert.agent,
    },
    alert_id: alert.id,
    ref: alert.ref ?? null,
  });

  const token = await providerToken();
  let sent = 0;
  for (const d of devices) {
    const host = d.environment === "sandbox" ? "api.sandbox.push.apple.com" : "api.push.apple.com";
    const res = await fetch(`https://${host}/3/device/${d.token}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${token}`,
        "apns-topic": Deno.env.get("APNS_BUNDLE_ID")!,
        "apns-push-type": "alert",
        "apns-priority": "10",
      },
      body: payload,
    });
    if (res.ok) sent++;
    else if (res.status === 410) await db.from("devices").delete().eq("token", d.token); // token caducado
    else console.error("apns:", res.status, await res.text());
  }
  if (sent) await db.from("alerts").update({ pushed_at: new Date().toISOString() }).eq("id", alert.id);
  return json({ ok: true, sent });
});
