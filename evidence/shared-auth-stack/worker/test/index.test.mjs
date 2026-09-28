import assert from "node:assert/strict";
import test from "node:test";

import { handleRequest, raceProviders } from "../src/index.mjs";

const config = {
  supabaseUrl: new URL("https://supa.example.test"),
  supabasePublishableKey: "sb_publishable_abcdefghijklmnopqrstuvwxyz",
  neonAuthUrl: new URL("https://neon.example.test/neondb/auth"),
  sharedAuthBase: new URL("http://127.0.0.1:8120"),
};

function jsonResponse(status, value, headers = {}) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json", ...headers },
  });
}

function delayed(ms, response) {
  return new Promise((resolve) => setTimeout(() => resolve(response), ms));
}

function providerFetch({
  supabaseDelay = 1,
  neonDelay = 1,
  supabaseStatus = 200,
  neonStatus = 200,
  neonIssuesSession = true,
} = {}) {
  return async (target, init = {}) => {
    const url = String(target);
    if (url.includes("supa.example.test")) {
      return delayed(supabaseDelay, jsonResponse(supabaseStatus, { access_token: "s".repeat(64) }));
    }
    if (url.endsWith("/neondb/auth/token")) {
      assert.match(init.headers.cookie, /better-auth\.session_token=/);
      return jsonResponse(200, { token: "n".repeat(64) });
    }
    if (url.includes("neon.example.test")) {
      const headers = neonIssuesSession
        ? { "set-cookie": "better-auth.session_token=opaque-session; Path=/; HttpOnly; Secure; SameSite=Lax" }
        : {};
      return delayed(neonDelay, jsonResponse(neonStatus, { user: { id: "neon-user" } }, headers));
    }
    throw new Error(`unexpected URL ${url}`);
  };
}

const credentials = { email: "user@example.test", password: "correct-horse-battery-staple" };

test("completion order changes telemetry winner but never the proof pair", async () => {
  const supabaseFirst = await raceProviders(
    "sign-in",
    credentials,
    config,
    providerFetch({ supabaseDelay: 1, neonDelay: 15 }),
  );
  const neonFirst = await raceProviders(
    "sign-in",
    credentials,
    config,
    providerFetch({ supabaseDelay: 15, neonDelay: 1 }),
  );

  assert.equal(supabaseFirst.ok, true);
  assert.equal(neonFirst.ok, true);
  assert.equal(supabaseFirst.first_provider, "supabase");
  assert.equal(neonFirst.first_provider, "neon");
  assert.equal(supabaseFirst.supabase_access_token, neonFirst.supabase_access_token);
  assert.equal(supabaseFirst.neon_access_token, neonFirst.neon_access_token);
});

test("Neon session cookie is exchanged for JWT and never returned as provider evidence", async () => {
  const result = await raceProviders("sign-in", credentials, config, providerFetch());
  assert.equal(result.ok, true);
  assert.equal(result.neon_access_token, "n".repeat(64));
  assert.equal(JSON.stringify(result).includes("opaque-session"), false);
});

test("one invalid provider hard-denies even when the other provider succeeds", async () => {
  const result = await raceProviders(
    "sign-in",
    credentials,
    config,
    providerFetch({ neonStatus: 401 }),
  );
  assert.deepEqual(result, { ok: false, status: 401, error: "invalid_credentials" });
});

test("one unavailable provider fails closed as unavailable", async () => {
  const result = await raceProviders(
    "sign-in",
    credentials,
    config,
    providerFetch({ supabaseStatus: 503 }),
  );
  assert.deepEqual(result, { ok: false, status: 503, error: "provider_unavailable" });
});

test("signup without a provider session reports verification required and creates no canonical binding", async () => {
  const result = await raceProviders(
    "sign-up",
    { ...credentials, name: "Example User" },
    config,
    providerFetch({ neonIssuesSession: false }),
  );
  assert.deepEqual(result, { ok: false, status: 202, error: "verification_required" });
});

test("full request calls Shared Auth exactly once after both providers succeed", async () => {
  let sharedAuthCalls = 0;
  const fetchImpl = async (target, init = {}) => {
    const url = String(target);
    if (url.includes("supabase.example.test")) {
      return jsonResponse(200, { access_token: "s".repeat(64) });
    }
    if (url.endsWith("/neondb/auth/token")) {
      assert.match(init.headers.cookie, /better-auth\.session_token=/);
      return jsonResponse(200, { token: "n".repeat(64) });
    }
    if (url.includes("neon.example.test")) {
      return jsonResponse(
        200,
        { user: { id: "neon-user" } },
        { "set-cookie": "better-auth.session_token=opaque-session; Path=/; HttpOnly; Secure" },
      );
    }
    if (url.includes("127.0.0.1:8120/auth/providers/exchange")) {
      sharedAuthCalls += 1;
      const body = JSON.parse(init.body);
      assert.equal(body.supabase_access_token, "s".repeat(64));
      assert.equal(body.neon_access_token, "n".repeat(64));
      assert.equal(init.body.includes("opaque-session"), false);
      return jsonResponse(200, { access_token: "canonical", provider: "dual_provider" });
    }
    throw new Error(`unexpected URL ${url}`);
  };
  const env = {
    SUPABASE_URL: "https://supabase.example.test",
    SUPABASE_PUBLISHABLE_KEY: "sb_publishable_abcdefghijklmnopqrstuvwxyz",
    NEON_AUTH_URL: "https://neon.example.test/neondb/auth",
    SHARED_AUTH_BASE: "http://127.0.0.1:8120",
  };
  const request = new Request("https://edge.example.test/auth/sign-in", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(credentials),
  });
  const response = await handleRequest(request, env, fetchImpl);
  assert.equal(response.status, 200);
  assert.equal(sharedAuthCalls, 1);
  assert.equal(response.headers.get("x-ores-provider-race-first") !== null, true);
});

test("Shared Auth is never called after a provider failure", async () => {
  let sharedAuthCalls = 0;
  const fetchImpl = async (target) => {
    const url = String(target);
    if (url.includes("supabase.example.test")) {
      return jsonResponse(200, { access_token: "s".repeat(64) });
    }
    if (url.includes("neon.example.test")) {
      return jsonResponse(401, { error: "bad credentials" });
    }
    sharedAuthCalls += 1;
    return jsonResponse(500, {});
  };
  const env = {
    SUPABASE_URL: "https://supabase.example.test",
    SUPABASE_PUBLISHABLE_KEY: "sb_publishable_abcdefghijklmnopqrstuvwxyz",
    NEON_AUTH_URL: "https://neon.example.test/neondb/auth",
    SHARED_AUTH_BASE: "http://127.0.0.1:8120",
  };
  const response = await handleRequest(
    new Request("https://edge.example.test/auth/sign-in", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(credentials),
    }),
    env,
    fetchImpl,
  );
  assert.equal(response.status, 401);
  assert.equal(sharedAuthCalls, 0);
});
