// Discourse 2026 derives the route-map filename from the plugin's manifest
// `name:` field. Our manifest is `discourse-coin-engine`, so this file must be
// `admin-discourse-coin-engine-route-map.js`. The earlier `admin-coin-engine-route-map.js`
// in the repo doesn't match the manifest and was silently ignored, which is why
// the Payments tab never appeared.
//
// Each `this.route(...)` call mounts as a child of `adminPlugins.show.discourse-coin-engine`
// and auto-renders as a tab at the top of the plugin admin page. The tab label
// is read from `admin_js.discourse_coin_engine.{route_name}.title` in client.en.yml.
export default function () {
  this.route("payments");
}
