// Retool Workflow: inspectionWebhook
// Trigger: webhook from the inspection app (one call per finished roof inspection).
// Blocks:  startTrigger -> verifySignature -> validate -> recordInspection (SQL) -> branchClaim
//          -> notifyEstimator (REST, retried) ; any failure -> errorHandler
// The code below is what goes into each JavaScript block. It is plain functions here so it can be tested.

const crypto = require('crypto');

// Block: verifySignature. Rejects anything not signed with our shared secret (stored in Retool config vars).
function verifySignature(rawBody, signatureHeader, secret) {
  if (!signatureHeader) throw new Error('missing signature');
  const expected = crypto.createHmac('sha256', secret).update(rawBody).digest('hex');
  const a = Buffer.from(expected), b = Buffer.from(String(signatureHeader).replace(/^sha256=/, ''));
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) throw new Error('bad signature');
  return true;
}

// Block: validate. Returns clean values for the SQL block, or throws a message a person can act on.
function validate(body) {
  const errors = [];
  const id = String(body?.inspection_id ?? '').trim();
  const jobId = Number(body?.job_id);
  const at = new Date(body?.completed_at);
  const hail = body?.hail_hits == null ? null : Number(body.hail_hits);
  if (!id) errors.push('inspection_id is required');
  if (!Number.isInteger(jobId) || jobId <= 0) errors.push('job_id must be a positive integer');
  if (isNaN(at)) errors.push('completed_at must be a date');
  else if (at > new Date(Date.now() + 10 * 60 * 1000)) errors.push('completed_at is in the future');
  if (hail !== null && (!Number.isInteger(hail) || hail < 0 || hail > 500)) errors.push('hail_hits must be 0-500');
  if (errors.length) { const e = new Error(errors.join('; ')); e.code = 'VALIDATION'; throw e; }
  return { externalId: id, jobId, inspectedAt: at.toISOString(), hailHits: hail,
           wind: Boolean(body.wind_damage), notes: String(body.notes ?? '').slice(0, 2000) };
}

// Block: branchClaim. Simple, explainable rule; the estimator decides, the workflow only suggests.
function suggestsClaim(v) {
  return (v.hailHits ?? 0) >= 8 || v.wind === true;
}

// Retry helper for the REST notify step (Retool blocks also have built-in retries; this adds jitter
// and only retries what is worth retrying).
async function withRetry(fn, { tries = 4, baseMs = 500, sleep = ms => new Promise(r => setTimeout(r, ms)) } = {}) {
  let last;
  for (let i = 0; i < tries; i++) {
    try { return await fn(i); }
    catch (e) {
      last = e;
      const status = e.status ?? 0;
      if (status && status < 500 && status !== 429) throw e;       // 4xx other than 429: do not retry
      if (i < tries - 1) await sleep(baseMs * 2 ** i + Math.floor(Math.random() * 100));
    }
  }
  throw last;
}

// Block: errorHandler. One message per failure, with enough context to replay the webhook.
function errorReport(err, body) {
  return {
    severity: err.code === 'VALIDATION' ? 'warning' : 'error',
    summary: `inspectionWebhook failed: ${err.message}`,
    inspection_id: body?.inspection_id ?? null,
    job_id: body?.job_id ?? null,
    replay: 'Fix the cause, then re-run this execution from the Retool Workflow run history',
  };
}

module.exports = { verifySignature, validate, suggestsClaim, withRetry, errorReport };
