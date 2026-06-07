import RouteTemplate from "ember-route-template";

// Payments tab content. Iframes the standalone admin URL which lives outside
// /admin/plugins/* (that namespace is owned by Discourse's Ember plugin show
// route). Converted from .hbs (deprecated) to .gjs — 2026-06-07.
export default RouteTemplate(
  <template>
    <div class="coin-engine-payments-tab" style="margin: 16px 0;">
      <div
        style="margin-bottom: 12px; display: flex; justify-content: space-between; align-items: baseline; flex-wrap: wrap; gap: 12px;"
      >
        <div>
          <h2 style="margin: 0 0 4px; font-size: 18px; font-weight: 800;">Manual Payments</h2>
          <p style="margin: 0; color: #5a6573; font-size: 13.5px; line-height: 1.5;">
            Search a recipient, set the amount, review, send. Each payment credits the user,
            appends to the public ledger, emails the recipient, and creates a permanent receipt PM.
          </p>
        </div>
        <a
          href="/admin/coin-engine"
          target="_blank"
          rel="noopener"
          style="font-size: 12.5px; color: #ff6b35; text-decoration: none; font-weight: 700; white-space: nowrap;"
        >
          Open in full window &rarr;
        </a>
      </div>

      <iframe
        src="/admin/coin-engine/embed"
        title="Coin Engine Manual Payments"
        loading="eager"
        style="width: 100%; height: 1200px; border: 1px solid rgba(15,22,36,.1); border-radius: 12px; background: #fff; display: block;"
      >
      </iframe>
    </div>
  </template>
);
