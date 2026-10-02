import assert from "node:assert/strict";
import test from "node:test";

import { handleRequest } from "../src/index.mjs";

function jsonResponse(status, value, headers = {}) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json", ...headers },
  });
}

function baseEnv(overrides = {}) {
  return {
    SUPABASE_URL: "https://supabase.example.test",
    SUPABASE_PUBLISHABLE_KEY: "sb_publishable_abcdefghijklmnopqrstuvwxyz",
    NEON_AUTH_URL: "https://neon.example.test/neondb/auth",
    SHARED_AUTH_BASE: "http://127.0.0.1:8120",
    APP_ORIGINS: "https://app.example.test",
    ...overrides,
  };
}

function loginRequest(origin = "https://app.example.test") {
  return new Request("https://edge.example.test/auth/sign-in", {
    method: "POST",
    headers: { "content-type": "application/json", origin },
    body: JSON.stringify({
      email: "user@example.test",
      password: "correct-horse-battery-staple",
    }),
  });
}

test("non-loopback plaintext Shared Auth origin is rejected before any network call", async () => {
  let calls = 0;
  const response = await handleRequest(
    loginRequest(),
    baseEnv({ SHARED_AUTH_BASE: "http://attacker.example" }),
    async () => {
      calls += 1;
      throw new Error("network must not be reached");
    },
  );
  const payload = await response.json();
  assert.equal(response.status, 503);
  assert.equal(payload.error, "auth_edge_misconfigured");
  assert.equal(calls, 0);
});

test("unknown browser origin receives no CORS grant", async () => {
  const response = await handleRequest(
    loginRequest("https://evil.example"),
    baseEnv(),
    async () => jsonResponse(401, { error: "bad credentials" }),
  );
  assert.equal(response.headers.get("access-control-allow-origin"), null);
});

test("oversized JSON body is rejected before provider traffic", async () => {
  let calls = 0;
  const body = JSON.stringify({ email: "u@example.test", password: "x".repeat(17000) });
  const response = await handleRequest(
    new Request("https://edge.example.test/auth/sign-in", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body,
    }),
    baseEnv(),
    async () => {
      calls += 1;
      return jsonResponse(500, {});
    },
  );
  assert.equal(response.status, 413);
  assert.equal(calls, 0);
});

test("canonical response never exposes either provider token", async () => {
  const supabaseToken = "s".repeat(64);
  const neonToken = "n".repeat(64);
  const fetchImpl = async (target, init = {}) => {
    const url = String(target);
    if (url.includes("supabase.example.test")) {
      return jsonResponse(200, { access_token: supabaseToken });
    }
    if (url.endsWith("/neondb/auth/token")) {
      return jsonResponse(200, { token: neonToken });
    }
    if (url.includes("neon.example.test")) {
      return jsonResponse(200, { user: { id: "neon-user" } }, {
        "set-cookie": "better-auth.session_token=opaque; Path=/; HttpOnly; Secure",
      });
    }
    if (url.includes("127.0.0.1:8120/auth/providers/exchange")) {
      const forwarded = JSON.parse(init.body);
      assert.equal(forwarded.supabase_access_token, supabaseToken);
      assert.equal(forwarded.neon_access_token, neonToken);
      return jsonResponse(200, { access_token: "canonical-token", shared_user_id: "shared-user" });
    }
    throw new Error(`unexpected URL ${url}`);
  };

  const response = await handleRequest(loginRequest(), baseEnv(), fetchImpl);
  const text = await response.text();
  assert.equal(response.status, 200);
  assert.equal(text.includes(supabaseToken), false);
  assert.equal(text.includes(neonToken), false);
  assert.match(text, /canonical-token/);
});

test("canonical exchange waits for both provider arms to settle", async () => {
  let neonSettled = false;
  let canonicalCalls = 0;
  const fetchImpl = async (target, init = {}) => {
    const url = String(target);
    if (url.includes("supabase.example.test")) {
      return jsonResponse(200, { access_token: "s".repeat(64) });
    }
    if (url.includes("neon.example.test") && !url.endsWith("/token")) {
      await new Promise((resolve) => setTimeout(resolve, 30));
      neonSettled = true;
      return jsonResponse(200, {}, {
        "set-cookie": "better-auth.session_token=opaque; Path=/; HttpOnly; Secure",
      });
    }
    if (url.endsWith("/neondb/auth/token")) {
      assert.equal(neonSettled, true);
      return jsonResponse(200, { token: "n".repeat(64) });
    }
    if (url.includes("127.0.0.1:8120/auth/providers/exchange")) {
      canonicalCalls += 1;
      assert.equal(neonSettled, true);
      assert.ok(JSON.parse(init.body).neon_access_token);
      return jsonResponse(200, { access_token: "canonical" });
    }
    throw new Error(`unexpected URL ${url}`);
  };

  const response = await handleRequest(loginRequest(), baseEnv(), fetchImpl);
  assert.equal(response.status, 200);
  assert.equal(canonicalCalls, 1);
});
