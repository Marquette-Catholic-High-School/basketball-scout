// Thin wrapper around the JSON API (docs/ARCHITECTURE.md "HTTP API").
// HTTP Basic auth is handled by the browser: same-origin requests send it.

import { sleep } from "./ui.js";

/** An API failure carrying the server's ErrorInfo {code, title, message, hint, retryable, detail}. */
export class ApiError extends Error {
  constructor(info, status = 0, body = null) {
    super(info.message || info.title || "Request failed");
    this.name = "ApiError";
    this.info = info;
    this.status = status;
    this.body = body;
  }

  get code() {
    return this.info.code;
  }
}

const NETWORK_ERROR = {
  code: "NETWORK_ERROR",
  title: "Can't reach the server",
  message: "The browser could not reach the Basketball Scout server.",
  hint: "Check the network connection (or that the server is running) and try again.",
  retryable: true,
};

/** Coach-friendly fallback when the response is not our JSON error (proxy pages, crashes). */
function fallbackInfo(status) {
  if (status === 401) {
    return { code: "AUTH_REQUIRED", title: "Please sign in", message: "The server asked for your username and password.", hint: "Reload the page and sign in.", retryable: false };
  }
  if (status === 413) {
    return { code: "UPLOAD_TOO_LARGE", title: "Request too large", message: "The server refused a request that was too large.", hint: "If the server runs behind nginx, raise client_max_body_size (see deploy/nginx).", retryable: false };
  }
  if (status >= 502 && status <= 504) {
    return { code: "SERVER_UNAVAILABLE", title: "Server unavailable", message: "The server is not responding right now (it may be restarting).", hint: "Wait a moment and try again.", retryable: true };
  }
  return { code: "HTTP_" + status, title: "Unexpected error", message: `The server answered with status ${status}.`, hint: "Try again; if it keeps happening check the server logs.", retryable: status >= 500 };
}

/** Build an ApiError from a status code and response text. */
export function errorFromResponse(status, text) {
  let body = null;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = null;
  }
  const raw = body && body.error && body.error.title ? body.error : null;
  const info = raw ? { ...raw } : fallbackInfo(status);
  if (info.code === "VALIDATION_FAILED" && info.detail) info.message = `${info.message} ${info.detail}`;
  return new ApiError(info, status, body);
}

function networkError() {
  return new ApiError({ ...NETWORK_ERROR });
}

/**
 * Send a request. Options: json (body to JSON-encode), body (raw body, e.g. FormData),
 * as ("json" | "text"), signal. Returns parsed JSON, text, or null for 204.
 */
export async function request(method, path, { json, body, as = "json", signal, headers = {} } = {}) {
  const init = { method, headers: { Accept: as === "json" ? "application/json" : "*/*", ...headers }, signal, credentials: "same-origin" };
  if (json !== undefined) {
    init.headers["Content-Type"] = "application/json";
    init.body = JSON.stringify(json);
  } else if (body !== undefined) {
    init.body = body;
  }
  let response;
  try {
    response = await fetch(path, init);
  } catch (err) {
    if (err && err.name === "AbortError") throw err;
    throw networkError();
  }
  const text = await response.text();
  if (!response.ok) throw errorFromResponse(response.status, text);
  if (response.status === 204 || !text) return null;
  if (as === "text") return text;
  try {
    return JSON.parse(text);
  } catch {
    throw new ApiError({ code: "BAD_RESPONSE", title: "Unexpected server response", message: "The server sent something the page could not read.", hint: "Reload the page; if it keeps happening check the server logs.", retryable: true }, response.status);
  }
}

export const api = {
  get: (path, opts) => request("GET", path, opts),
  text: (path, opts) => request("GET", path, { ...opts, as: "text" }),
  post: (path, json, opts) => request("POST", path, { ...opts, json }),
  put: (path, json, opts) => request("PUT", path, { ...opts, json }),
  patch: (path, json, opts) => request("PATCH", path, { ...opts, json }),
  del: (path, opts) => request("DELETE", path, opts),
  upload: (path, formData, opts) => request("POST", path, { ...opts, body: formData }),
};

/** "/api/games/<id><suffix>" with the id safely encoded. */
export function gamePath(gameId, suffix = "") {
  return `/api/games/${encodeURIComponent(gameId)}${suffix}`;
}

export function jobPath(jobId, suffix = "") {
  return `/api/jobs/${encodeURIComponent(jobId)}${suffix}`;
}

const ACTIVE_JOB_STATUSES = new Set(["queued", "running"]);

export function isJobActive(job) {
  return Boolean(job && ACTIVE_JOB_STATUSES.has(job.status));
}

/**
 * Poll a job until it leaves queued/running. Calls onUpdate(job) after every poll.
 * Network hiccups are retried; the signal stops polling (rejects with AbortError).
 */
export async function pollJob(jobId, onUpdate, { intervalMs = 3000, signal } = {}) {
  let failures = 0;
  for (;;) {
    try {
      const job = await api.get(jobPath(jobId), { signal });
      failures = 0;
      onUpdate?.(job);
      if (!isJobActive(job)) return job;
    } catch (err) {
      if (err.name === "AbortError") throw err;
      failures += 1;
      if (failures >= 5 || !(err.info && err.info.retryable)) throw err;
    }
    await sleep(intervalMs, signal);
  }
}

/**
 * PUT one upload chunk with XMLHttpRequest (fetch has no upload progress).
 * Resolves with the UploadSession; rejects with ApiError (status 409 carries the
 * current session in err.body) or an AbortError DOMException.
 */
export function putChunk(uploadId, offset, blob, { onProgress, signal } = {}) {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open("PUT", `/api/uploads/${encodeURIComponent(uploadId)}/chunk?offset=${offset}`);
    xhr.setRequestHeader("Content-Type", "application/octet-stream");
    xhr.setRequestHeader("Accept", "application/json");
    xhr.upload.onprogress = (e) => onProgress?.(e.loaded);
    xhr.onload = () => {
      if (xhr.status >= 200 && xhr.status < 300) {
        try {
          resolve(JSON.parse(xhr.responseText));
        } catch {
          reject(errorFromResponse(xhr.status, ""));
        }
      } else {
        reject(errorFromResponse(xhr.status, xhr.responseText));
      }
    };
    xhr.onerror = () => reject(networkError());
    xhr.ontimeout = () => reject(networkError());
    xhr.onabort = () => reject(new DOMException("Aborted", "AbortError"));
    if (signal) {
      if (signal.aborted) {
        reject(new DOMException("Aborted", "AbortError"));
        return;
      }
      signal.addEventListener("abort", () => xhr.abort(), { once: true });
    }
    xhr.send(blob);
  });
}
