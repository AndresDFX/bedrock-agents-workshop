/**
 * Placeholder sustituido por deploy.sh tras CloudFormation (Function URL).
 *
 * IMPORTANTE: deploy.sh hace un replace LITERAL de la cadena __FUNCTION_URL__
 * en TODO el archivo. Por eso esa cadena solo debe aparecer UNA vez (en la
 * constante de abajo). Para detectar que aún no fue reemplazada, comprobamos
 * que el valor empiece por "https://", evitando que el replace toque el check.
 */
const FUNCTION_URL = "__FUNCTION_URL__";

function $(id) {
  const el = document.getElementById(id);
  if (!el) throw new Error(`Missing #${id}`);
  return el;
}

async function consumeStreamingBody(response, onText) {
  const reader = response.body?.getReader();
  if (!reader) {
    const text = await response.text();
    onText(text);
    return;
  }
  const decoder = new TextDecoder();
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    if (value && value.byteLength) {
      onText(decoder.decode(value, { stream: true }));
    }
  }
}

async function runMode(mode, prompt, outEl, statusEl) {
  outEl.textContent = "";
  statusEl.textContent = "Pensando…";
  statusEl.classList.add("active");

  if (!FUNCTION_URL || !FUNCTION_URL.startsWith("https://")) {
    statusEl.textContent = "Error: FUNCTION_URL no configurada (ejecuta deploy.sh).";
    statusEl.classList.remove("active");
    return;
  }

  const resp = await fetch(FUNCTION_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ prompt, mode }),
  });

  if (!resp.ok) {
    const errText = await resp.text().catch(() => "");
    statusEl.textContent = `HTTP ${resp.status} ${resp.statusText}${errText ? ` — ${errText.slice(0, 400)}` : ""}`;
    statusEl.classList.remove("active");
    return;
  }

  let sawChunk = false;
  await consumeStreamingBody(resp, (chunk) => {
    if (!chunk) return;
    if (!sawChunk) {
      sawChunk = true;
      statusEl.textContent = "Recibiendo tokens…";
    }
    outEl.textContent += chunk;
  });

  statusEl.textContent = sawChunk ? "Completado." : "(vacío)";
  statusEl.classList.remove("active");
}

function wireUi() {
  const btn = $("compare");
  const ta = $("prompt");
  const globalStatus = $("global-status");

  const outBot = $("out-chatbot");
  const outAgent = $("out-agent");
  const stBot = $("st-chatbot");
  const stAgent = $("st-agent");

  btn.addEventListener("click", async () => {
    const prompt = ta.value.trim();
    if (!prompt) {
      globalStatus.textContent = "Escribe un mensaje antes de comparar.";
      return;
    }

    btn.disabled = true;
    globalStatus.textContent = "Invocando ambas columnas en paralelo…";

    try {
      await Promise.all([
        runMode("chatbot", prompt, outBot, stBot),
        runMode("agent", prompt, outAgent, stAgent),
      ]);
      globalStatus.textContent = "Listo.";
    } catch (err) {
      globalStatus.textContent = `Error: ${err && err.message ? err.message : String(err)}`;
    } finally {
      btn.disabled = false;
    }
  });
}

wireUi();
