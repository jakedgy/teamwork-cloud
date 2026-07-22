(() => {
  "use strict";

  const grid = document.querySelector("#health-grid");
  const updated = document.querySelector("#health-updated");
  if (!grid || !updated) return;

  const field = (list, label, value) => {
    const term = document.createElement("dt");
    term.textContent = label;
    const detail = document.createElement("dd");
    detail.textContent = value;
    list.append(term, detail);
  };

  const displayTime = (value) => value && !value.startsWith("0001-")
    ? new Date(value).toLocaleString()
    : "Waiting for first check";

  const serviceCard = (service) => {
    const card = document.createElement("article");
    card.className = "card service-card";
    card.dataset.status = service.status;
    const heading = document.createElement("h3");
    heading.textContent = service.name;
    const details = document.createElement("dl");
    field(details, "State", service.status);
    field(details, "Endpoint", service.endpoint);
    field(details, "Last attempt", displayTime(service.checkedAt));
    field(details, "Last success", displayTime(service.lastSuccessAt));
    field(details, "Latency", `${service.latencyMillis} ms`);
    if (service.error) field(details, "Summary", service.error);
    card.append(heading, details);
    return card;
  };

  const refresh = async () => {
    try {
      const response = await fetch("/api/health", { headers: { Accept: "application/json" } });
      if (!response.ok) throw new Error("Health request failed");
      const payload = await response.json();
      grid.replaceChildren(...payload.services.map(serviceCard));
      updated.textContent = payload.checkedAt && !payload.checkedAt.startsWith("0001-")
        ? `Updated ${new Date(payload.checkedAt).toLocaleTimeString()}`
        : "Waiting for first check";
    } catch (_) {
      grid.replaceChildren();
      updated.textContent = "Health data temporarily unavailable";
    }
  };

  refresh();
  window.setInterval(refresh, 10_000);
})();
