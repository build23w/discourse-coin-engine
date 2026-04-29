// Discourse auto-discovers files matching `admin-{plugin-name}-route-map.js`
// and mounts each `this.route(...)` as a child of `adminPlugins.show.{plugin-name}`.
// Each child route auto-renders as a tab at the top of the plugin admin page,
// next to the default "Settings" tab. The tab label is read from
// `admin_js.coin_engine.{route_name}.title` in client.en.yml.
export default function () {
  this.route("payments");
}
