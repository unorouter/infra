// Upstream canary. A fake provider channel in the gateway points its base_url here with a
// key that exists nowhere else. Nothing legitimate ever calls this host, so every request
// is someone who read the channels table (or a dump of it) and is trying the key. The
// answer imitates a dead OpenAI key so the caller learns nothing; the alert carries the
// caller's address, network, agent and the key prefix, and goes straight to Discord.
const OWN_NETWORKS = (env) => (env.OWN_NETWORKS || "").split(",").map((s) => s.trim()).filter(Boolean);

function ipToBits(ip) {
  if (ip.includes(":")) {
    const [head, tail] = ip.split("::");
    const h = head ? head.split(":") : [];
    const t = tail ? tail.split(":") : [];
    const groups = [...h, ...Array(8 - h.length - t.length).fill("0"), ...t];
    return groups.map((g) => parseInt(g || "0", 16).toString(2).padStart(16, "0")).join("");
  }
  return ip.split(".").map((o) => (+o).toString(2).padStart(8, "0")).join("");
}

function inOwn(ip, prefixes) {
  if (!ip) return false;
  const v6 = ip.includes(":");
  const bits = ipToBits(ip);
  return prefixes.some((p) => {
    const [net, len] = p.split("/");
    if (net.includes(":") !== v6) return false;
    const n = len === undefined ? bits.length : +len;
    return ipToBits(net).slice(0, n) === bits.slice(0, n);
  });
}

export default {
  async fetch(request, env) {
    const cf = request.cf || {};
    const ip = request.headers.get("cf-connecting-ip") || "";
    const auth = request.headers.get("authorization") || request.headers.get("x-api-key") || request.headers.get("api-key") || "";
    const keyPrefix = auth.replace(/^Bearer\s+/i, "").slice(0, 16);
    const url = new URL(request.url);
    const body = request.method === "POST" ? (await request.text()).slice(0, 300) : "";
    const own = inOwn(ip, OWN_NETWORKS(env));
    const lines = [
      `**CANARY HIT** ${own ? "(own network, probably a channel test)" : "@here"}`,
      `ip: \`${ip}\`  asn: ${cf.asn || "?"} ${cf.asOrganization || ""}  country: ${cf.country || "?"}`,
      `${request.method} ${url.pathname}${url.search}`,
      `ua: \`${(request.headers.get("user-agent") || "").slice(0, 120)}\``,
      `key: \`${keyPrefix}...\`  tls: ${cf.tlsVersion || "?"}  http: ${cf.httpProtocol || "?"}`,
      body ? `body: \`${body.replace(/`/g, "'")}\`` : "",
    ].filter(Boolean);
    if (env.DISCORD_WEBHOOK) {
      await fetch(env.DISCORD_WEBHOOK, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ username: "upstream canary", content: lines.join("\n").slice(0, 1900) }),
      }).catch(() => {});
    }
    return new Response(
      JSON.stringify({ error: { message: "Incorrect API key provided: " + keyPrefix + "***. You can find your API key at https://platform.openai.com/account/api-keys.", type: "invalid_request_error", param: null, code: "invalid_api_key" } }),
      { status: 401, headers: { "content-type": "application/json", "x-request-id": crypto.randomUUID() } }
    );
  },
};
