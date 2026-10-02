// PNGs are bundled as raw bytes (the "Data" rule in wrangler.toml).
declare module '*.png' {
  const data: ArrayBuffer;
  export default data;
}
